import Foundation
import Observation

/// Everything `VoiceRecordingSession` needs that this package cannot provide itself — mirrors
/// `PaiRequestFactory`'s `tokenProvider` in style: closures read at call time, not values
/// captured once, so a change to settings takes effect on the next recording without rebuilding
/// anything.
///
/// `now` and `sleep` exist for exactly one reason: silence detection and the post-commit wait
/// are entirely about durations, and a test that waits out real durations is slow and eventually
/// flaky. Production supplies real time; tests supply a fake clock and an instant `sleep`.
public struct VoiceRecordingDependencies: Sendable {
    public var mintToken: @Sendable (VoiceTokenPurpose) async throws -> VoiceToken
    public var makeRealtimeTransport: @Sendable () -> VoiceRealtimeTransport
    public var settings: @Sendable () -> VoiceSettings
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Duration) async -> Void

    public init(
        mintToken: @escaping @Sendable (VoiceTokenPurpose) async throws -> VoiceToken,
        makeRealtimeTransport: @escaping @Sendable () -> VoiceRealtimeTransport,
        settings: @escaping @Sendable () -> VoiceSettings,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.mintToken = mintToken
        self.makeRealtimeTransport = makeRealtimeTransport
        self.settings = settings
        self.now = now
        self.sleep = sleep
    }
}

/// The recording lifecycle end to end: mint a fresh token, connect, stream audio the app hands
/// over, decide when to stop (the user, silence, an interruption, a lost connection, a protocol
/// error), and hand back a prefixed transcript. Everything a live microphone would otherwise
/// supply — amplitude samples, PCM buffers, a clock, the realtime socket itself — arrives through
/// `VoiceRecordingDependencies` or the `ingest*` methods, which is what makes every branch here
/// reachable from a unit test.
///
/// `@MainActor` for the same reason `PaiSseClient` is: every realistic caller is a UI-driven view
/// model reading `state`/`transcribedText` to render, and the event rate here (audio chunks,
/// transcript messages) is nowhere near where hopping onto the main actor per call would cost
/// anything. Because of this, `ingestAudioChunk` must never be called directly from an audio
/// render thread — the app is expected to hop off that thread first, the same way it already
/// must before touching any other `@MainActor` state.
@MainActor
@Observable
public final class VoiceRecordingSession {
    public private(set) var state: VoiceRecordingState = .idle
    public private(set) var isMuted = false
    /// Committed segments plus the current partial, joined and unprefixed. A caller streaming
    /// this into a composer inserts `VoiceRecordingResult.sttPrefix` once, at the moment
    /// recording starts, and keeps replacing everything after it with this — the same shape as
    /// the web's `MessageInput.tsx` live effect. The final, one-shot prefixed string is
    /// `result.prefixedText` after `stop()` returns.
    public private(set) var transcribedText = ""
    public private(set) var lastEndReason: RecordingEndReason?
    /// Set only when `start()` itself failed — token mint, URL construction, transport connect.
    /// A failure mid-recording (the `.error` protocol message) is reported through
    /// `lastProtocolErrorMessage` and `lastEndReason == .error` instead, since by then a start
    /// failure's distinctions (key/service/permission) no longer apply.
    public private(set) var lastStartFailure: VoiceStartFailure?
    public private(set) var lastProtocolErrorMessage: String?

    private let dependencies: VoiceRecordingDependencies
    private var transport: VoiceRealtimeTransport?
    private var receiveTask: Task<Void, Never>?
    private var preconnectBuffer = PreconnectAudioBuffer<RealtimeUplinkChunk>()
    private var silenceDetector: SilenceDetector?
    private var committedSegments: [String] = []
    private var partial = ""
    private var recordingStart: Date?
    private var transportRateHz = 24000
    private var narrowband = false
    private var mutedMs = 0
    private var lastMuteToggle: Date?
    private var awaitingFinalCommit = false
    private var isStopping = false

    public init(dependencies: VoiceRecordingDependencies) {
        self.dependencies = dependencies
    }

    public var canStart: Bool { state == .idle }

    public var result: VoiceRecordingResult {
        VoiceRecordingResult(
            text: transcribedText,
            endedBy: lastEndReason ?? .user,
            durationMs: recordingStart.map { Int(dependencies.now().timeIntervalSince($0) * 1000) } ?? 0,
            mutedMs: mutedMs,
            sampleRate: transportRateHz,
            narrowband: narrowband
        )
    }

    // MARK: Start

    /// Gated on `state == .idle` rather than a separate `elevenLabsKeySet` flag: the mint itself
    /// is the source of truth on whether a key is configured (503), and checking a cached flag
    /// first would only reproduce the web's cold-start bug where a stale `null` blocks a
    /// recording the backend would have accepted.
    public func start(hardwareSampleRate: Int) async {
        guard state == .idle else { return }
        state = .connecting
        resetTakeState()

        let settings = dependencies.settings()
        transportRateHz = VoiceAudioRatePolicy.transportRate(hardwareRate: hardwareSampleRate)
        narrowband = VoiceAudioRatePolicy.isNarrowband(rate: transportRateHz)
        silenceDetector = SilenceDetector(config: .from(settings))
        recordingStart = dependencies.now()

        let token: VoiceToken
        do {
            // A fresh mint per recording — the token is single-use, so caching one across takes
            // would make the second recording in a session fail for no reason visible to the
            // user.
            token = try await dependencies.mintToken(.realtime)
        } catch {
            lastStartFailure = VoiceStartFailure.classify(error)
            state = .idle
            return
        }

        guard
            let url = VoiceRealtimeProtocol.connectionURL(
                token: token.token, sampleRate: transportRateHz, language: settings.sttLanguage
            )
        else {
            lastStartFailure = .other(.transport("Could not build the realtime connection URL"))
            state = .idle
            return
        }

        let transport = dependencies.makeRealtimeTransport()
        do {
            try await transport.connect(url: url)
        } catch {
            lastStartFailure = .other(.transport("\(error)"))
            state = .idle
            return
        }
        self.transport = transport

        receiveTask = Task { [weak self] in await self?.runReceiveLoop() }
    }

    private func resetTakeState() {
        committedSegments = []
        partial = ""
        transcribedText = ""
        lastEndReason = nil
        lastStartFailure = nil
        lastProtocolErrorMessage = nil
        mutedMs = 0
        isMuted = false
        lastMuteToggle = nil
        preconnectBuffer = PreconnectAudioBuffer()
    }

    // MARK: Receive loop

    private func runReceiveLoop() async {
        guard let transport else { return }
        while !Task.isCancelled {
            let text: String
            do {
                text = try await transport.receive()
            } catch {
                await handleConnectionLost()
                return
            }
            guard let message = RealtimeDownlinkMessage.decode(text) else { continue }
            await handle(message)
        }
    }

    private func handle(_ message: RealtimeDownlinkMessage) async {
        switch message {
        case .sessionStarted:
            // Flushing here rather than on the transport's own "open" event is Android's
            // ordering, and stricter than the web's: audio sent before ElevenLabs has actually
            // allocated the session has nowhere to go.
            guard state == .connecting else { return }
            state = .recording
            await flushPreconnectBuffer()

        case let .partialTranscript(text):
            partial = text
            updateTranscribedText()

        case let .committedTranscript(text):
            if !text.isEmpty { committedSegments.append(text) }
            partial = ""
            updateTranscribedText()
            awaitingFinalCommit = false

        case let .error(message):
            lastProtocolErrorMessage = message
            await finishStop(reason: .error)

        case .commitThrottled, .insufficientAudioActivity, .unrecognized:
            break
        }
    }

    private func updateTranscribedText() {
        transcribedText = (committedSegments + [partial]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func handleConnectionLost() async {
        guard state == .recording || state == .connecting else { return }
        await finishStop(reason: .connectionLost)
    }

    // MARK: Audio ingestion — everything the app supplies

    /// Feed one RMS reading, roughly every 100-200ms, on the same clock `start()` was called
    /// with. Drives silence detection only; never sent anywhere.
    public func ingestLevel(rms: Double) {
        guard state == .recording || state == .connecting,
            let recordingStart, var detector = silenceDetector
        else { return }
        let elapsedMs = Int(dependencies.now().timeIntervalSince(recordingStart) * 1000)
        let fired = detector.observe(rms: rms, elapsedMs: elapsedMs, muted: isMuted)
        silenceDetector = detector
        if fired {
            Task { await self.stop(reason: .silence) }
        }
    }

    /// Feed one buffer of mono PCM samples at the transport rate `start(hardwareSampleRate:)`
    /// negotiated — no resampling happens here, the app's `AVAudioConverter` already did it.
    /// `async` so the app awaits each call from its own capture-consuming task: that keeps
    /// chunks in order for free, the same guarantee `preConnectBuffer`'s `ConcurrentLinkedQueue`
    /// exists to provide on Android. Sent immediately once recording, buffered until
    /// `session_started` otherwise.
    ///
    /// While muted, the content actually sent is replaced with digital silence regardless of
    /// what was passed in — silence detection's `muted` guard only suppresses auto-stop, so this
    /// is the actual privacy guarantee, and it holds even if a bug elsewhere leaves the app's own
    /// track un-silenced.
    public func ingestAudioChunk(pcm16le samples: [Int16]) async {
        guard state == .recording || state == .connecting else { return }
        let effectiveSamples = isMuted ? [Int16](repeating: 0, count: samples.count) : samples
        let chunk = RealtimeUplinkChunk(
            audioBase64: RealtimeUplinkChunk.audioBase64(fromPCM16LE: effectiveSamples),
            commit: false,
            sampleRate: transportRateHz
        )
        if state == .recording {
            await send(chunk)
        } else {
            preconnectBuffer.enqueue(chunk)
        }
    }

    private func flushPreconnectBuffer() async {
        for chunk in preconnectBuffer.drain() {
            await send(chunk)
        }
    }

    private func send(_ chunk: RealtimeUplinkChunk) async {
        guard let data = try? chunk.encoded() else { return }
        try? await transport?.send(text: String(decoding: data, as: UTF8.self))
    }

    // MARK: Mute

    /// Everything else keeps running while muted — the processor still fires, the socket still
    /// receives frames (of silence, per `ingestAudioChunk`), the socket stays open, so the saved
    /// recording's timeline still matches the wall clock. `mutedMs` is accumulated so a short
    /// transcript on a long take explains itself.
    public func toggleMute() {
        let now = dependencies.now()
        if isMuted, let lastMuteToggle {
            mutedMs += Int(now.timeIntervalSince(lastMuteToggle) * 1000)
        }
        isMuted.toggle()
        lastMuteToggle = now
    }

    // MARK: Interruption — the app's `AVAudioSession.interruptionNotification` handler calls this

    /// Ends the take and keeps the words transcribed so far, the same policy the web applies to
    /// its `audioContext` being suspended in the background — deliberately reacting to the
    /// interruption itself, not to which platform caused it.
    public func handleInterruption() async {
        guard state == .recording || state == .connecting else { return }
        await stop(reason: .interrupted)
    }

    // MARK: Stop

    /// Idempotent: a second call while already stopping is a no-op rather than a second commit
    /// frame or a second `finishStop`.
    public func stop(reason: RecordingEndReason) async {
        guard state == .recording || state == .connecting else { return }
        guard !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        state = .stopping
        if transport != nil {
            awaitingFinalCommit = true
            let commitChunk = RealtimeUplinkChunk.commitFrame(sampleRate: transportRateHz)
            await send(commitChunk)

            var waitedMs = 0
            while WaitForCommitPolicy.shouldContinueWaiting(
                elapsedMs: waitedMs, commitReceived: !awaitingFinalCommit
            ) {
                await dependencies.sleep(.milliseconds(WaitForCommitPolicy.pollIntervalMs))
                waitedMs += WaitForCommitPolicy.pollIntervalMs
            }
        }
        await finishStop(reason: reason)
    }

    private func finishStop(reason: RecordingEndReason) async {
        receiveTask?.cancel()
        receiveTask = nil
        if let transport {
            await transport.close(code: 1000, reason: nil)
        }
        transport = nil
        lastEndReason = reason
        state = .idle
    }
}
