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
    /// The single in-flight reconnect episode, if any — `handleConnectionLost` and
    /// `resumeAfterInterruption` both reach it, and both cancel any prior one before starting a
    /// new one so a resume racing a still-sleeping retry can never produce two.
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var preconnectBuffer = PreconnectAudioBuffer<RealtimeUplinkChunk>()
    private var silenceDetector: SilenceDetector?
    private var committedSegments: [String] = []
    private var partial = ""
    private var recordingStart: Date?
    private var transportRateHz = 24000
    private var narrowband = false
    private var sttLanguage: VoiceSettings.Language = .auto
    private var mutedMs = 0
    private var lastMuteToggle: Date?
    private var awaitingFinalCommit = false
    private var isStopping = false

    public init(dependencies: VoiceRecordingDependencies) {
        self.dependencies = dependencies
    }

    public var canStart: Bool { state == .idle }

    /// The rate negotiated for this take, fixed for its whole duration — what the app resumes
    /// capture at after a pause, so `AVAudioConverter`'s target never changes mid-take even if
    /// the hardware's own rate does (a Bluetooth headset dropping out mid-call, say).
    public var transportSampleRateHz: Int { transportRateHz }

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
        sttLanguage = settings.sttLanguage
        silenceDetector = SilenceDetector(config: .from(settings))
        recordingStart = dependencies.now()

        do {
            try await connectTransport()
        } catch {
            lastStartFailure = Self.classifyConnectFailure(error)
            state = .idle
        }
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
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private enum ConnectFailure: Error {
        case mint(Error)
        case url
        case transport(Error)
    }

    private static func classifyConnectFailure(_ error: Error) -> VoiceStartFailure {
        switch error {
        case let ConnectFailure.mint(underlying): VoiceStartFailure.classify(underlying)
        case ConnectFailure.url: .other(.transport("Could not build the realtime connection URL"))
        case let ConnectFailure.transport(underlying): .other(.transport("\(underlying)"))
        default: VoiceStartFailure.classify(error)
        }
    }

    /// Mints a fresh token and opens a new transport connection, starting the receive loop.
    /// Shared by the first connect and a mid-take reconnect — neither may touch
    /// `committedSegments`/`partial`/`transcribedText`: the first because there is nothing yet to
    /// lose, a reconnect because losing it is exactly the bug reconnecting exists to avoid.
    /// Throws rather than setting `state`/`lastStartFailure` itself, since the two callers need
    /// different failure handling (give up entirely vs. try again).
    private func connectTransport() async throws {
        let token: VoiceToken
        do {
            // A fresh mint per attempt — the token is single-use, so caching one across a
            // reconnect would make the retry fail for no reason visible to the user, the same
            // logic that already ruled out caching one across separate takes.
            token = try await dependencies.mintToken(.realtime)
        } catch {
            throw ConnectFailure.mint(error)
        }

        guard
            let url = VoiceRealtimeProtocol.connectionURL(
                token: token.token, sampleRate: transportRateHz, language: sttLanguage
            )
        else {
            throw ConnectFailure.url
        }

        let transport = dependencies.makeRealtimeTransport()
        do {
            try await transport.connect(url: url)
        } catch {
            throw ConnectFailure.transport(error)
        }
        self.transport = transport
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in await self?.runReceiveLoop() }
    }

    // MARK: Receive loop

    private func runReceiveLoop() async {
        guard let transport else { return }
        while !Task.isCancelled {
            let text: String
            do {
                text = try await transport.receive()
            } catch {
                // `receive()` is not itself cancellation-aware — cancelling this task (as
                // `finishStop`/a reconnect both do) does not interrupt an in-flight call, only
                // the loop's own check below it. So closing the transport as part of that same
                // teardown wakes this suspended call with an error that looks exactly like a
                // real connection loss. Bailing out on `isCancelled` here is what keeps a
                // teardown from reconnecting into whatever take starts next.
                guard !Task.isCancelled else { return }
                let reason: String? =
                    if case let VoiceTransportError.connectionLost(reason) = error { reason } else { nil }
                await handleConnectionLost(closeReason: reason)
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
            // allocated the session has nowhere to go. Accepting `.reconnecting` too is what
            // makes a mid-take reconnect land in exactly the same place a first connect does.
            guard state == .connecting || state == .reconnecting else { return }
            state = .recording
            reconnectAttempt = 0
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

    /// A dropped socket no longer ends the take by itself — over the length of recording this
    /// feature is built for, a cellular handoff or a moment of dead signal is likely, and it
    /// carries no ElevenLabs close reason at all (`reason == nil`), unlike the one documented
    /// server-initiated close (`resource_exhausted`) `ReconnectPolicy` was ported from Android to
    /// recognise. Treating "no reason" as "assume transient, try again" is what actually covers
    /// that likely case; `ReconnectPolicy.shouldReconnect` still gates the case where a reason
    /// *is* known, so both call sites of that policy are exercised, not just the constructed one.
    private func handleConnectionLost(closeReason: String?) async {
        guard state == .recording || state == .connecting || state == .paused || state == .reconnecting else {
            return
        }
        guard closeReason == nil || ReconnectPolicy.shouldReconnect(closeReason: closeReason),
            let delay = ReconnectPolicy.delaySeconds(forAttempt: reconnectAttempt + 1)
        else {
            await finishStop(reason: .connectionLost)
            return
        }
        reconnectAttempt += 1
        state = .reconnecting
        transport = nil
        receiveTask?.cancel()
        receiveTask = nil

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            await self?.dependencies.sleep(.seconds(delay))
            await self?.performReconnectAttempt()
        }
    }

    /// The retry itself, shared by the backoff wait above and `resumeAfterInterruption`'s
    /// no-transport fallback — both leave `state == .reconnecting` and call straight into this,
    /// so there is exactly one place that mints the retry's token and opens its socket.
    private func performReconnectAttempt() async {
        // Torn down (stopped, or a later event already handled) while this was scheduled.
        guard state == .reconnecting else { return }
        do {
            try await connectTransport()
        } catch {
            await handleConnectionLost(closeReason: nil)
        }
    }

    // MARK: Audio ingestion — everything the app supplies

    /// Feed one RMS reading, roughly every 100-200ms, on the same clock `start()` was called
    /// with. Drives silence detection only; never sent anywhere.
    ///
    /// Deliberately not fed during `.reconnecting`, unlike `ingestAudioChunk` — a network gap
    /// reads as quiet on no evidence about the room at all, and firing an auto-stop from that
    /// would end a take purely because the socket dropped, exactly what reconnecting exists to
    /// prevent.
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
    ///
    /// `.reconnecting` buffers here exactly as `.connecting` does before the first
    /// `session_started` — speech spoken during a network gap is not lost, only delayed until the
    /// retry succeeds. `.paused` is deliberately excluded: the app is not capturing during an
    /// audio interruption, so nothing should be arriving to buffer in the first place.
    public func ingestAudioChunk(pcm16le samples: [Int16]) async {
        guard state == .recording || state == .connecting || state == .reconnecting else { return }
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

    /// The system has already taken the microphone, so capture must stop regardless of what
    /// happens next — but the take itself only pauses. A call, Siri, or another app taking the
    /// mic must resume into the same take once it ends, not start a fresh one: ending it here the
    /// way a short dictation always did would be the opposite of what an hour in a pocket needs.
    /// Cancels a pending reconnect rather than letting it fire with no mic to feed it — resuming
    /// (below) re-derives whether one is still needed from `transport` being `nil`.
    public func pauseForInterruption() {
        guard state == .recording || state == .connecting || state == .reconnecting else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        state = .paused
    }

    /// Called once the app has audio capture running again. Two cases, distinguished by whether
    /// `transport` survived the interruption: a live socket just needs `state` flipped back, but
    /// one already lost — an interruption landing mid-reconnect-backoff, say — needs a fresh
    /// attempt kicked off immediately rather than claiming `.recording` with nowhere to send to.
    public func resumeAfterInterruption() {
        guard state == .paused else { return }
        guard transport != nil else {
            state = .reconnecting
            reconnectTask?.cancel()
            reconnectTask = Task { [weak self] in await self?.performReconnectAttempt() }
            return
        }
        state = .recording
    }

    // MARK: Stop

    /// Idempotent: a second call while already stopping is a no-op rather than a second commit
    /// frame or a second `finishStop`.
    public func stop(reason: RecordingEndReason) async {
        guard state == .recording || state == .connecting || state == .paused || state == .reconnecting else {
            return
        }
        reconnectTask?.cancel()
        reconnectTask = nil
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
        reconnectTask?.cancel()
        reconnectTask = nil
        if let transport {
            await transport.close(code: 1000, reason: nil)
        }
        transport = nil
        lastEndReason = reason
        state = .idle
    }
}
