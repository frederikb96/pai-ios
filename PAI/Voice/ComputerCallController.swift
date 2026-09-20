import AVFoundation
import Foundation
import Observation
import PAIKit

/// Ties `PAIKit`'s `ComputerCallSession` (the tested decision core: connect/reconnect, the
/// switchboard's own state) to what only a real device can supply — `ComputerAudioIO`'s
/// microphone capture and speaker playback, permission handling, and `AVAudioSession`
/// interruption observation. Same split as `VoiceRecorderController`/`VoiceUplinkSession`, for
/// the same reason: the session has no idea a microphone exists, and this type has no idea a
/// backend does.
///
/// One instance for the app's life, exactly like `VoiceRecorderController` and for the same
/// reason: the microphone is a single exclusive resource, and a call is a thing Freddy starts
/// and then stops looking at. `ComputerCallView` is a window onto this, never its owner — so
/// backing out of that screen to read a session or a note leaves the call running, which is the
/// whole point of it. What ends a call is the End control, a sign-out, or the backend closing
/// the socket; nothing about navigation does.
@MainActor
@Observable
final class ComputerCallController {
    private(set) var session: ComputerCallSession
    private(set) var setupFailure: String?
    /// Derived client-side from downlink audio actually rendering, not from any backend
    /// `state.phase` push — `ComputerEngine` only ever sends `phase: "listening"`, once, on
    /// attach (`pai_cloud.computer.engine.ComputerEngine.attach`), so a client that wants to say
    /// "Computer is speaking" has to notice for itself, from the same completion receipts
    /// `notePlayed(ref:)` already needs.
    private(set) var isSpeaking = false
    private var pendingPlaybackChunks = 0

    private let audioIO = ComputerAudioIO()
    private let feedbackNotifier: VoiceFeedbackNotifier
    private let toasts: ToastCenter
    private let audioSession = AVAudioSession.sharedInstance()
    /// `nonisolated(unsafe)` so `deinit` — which is nonisolated — can unregister it, same
    /// discipline as `VoiceRecorderController.interruptionObserver`: written once on the main
    /// actor during setup and read once at deallocation, when nothing else holds a reference, so
    /// there is no concurrent access for the isolation to protect.
    private nonisolated(unsafe) var interruptionObserver: NSObjectProtocol?
    /// One ordered consumer for every captured chunk, not one unstructured `Task` per chunk —
    /// exactly `VoiceRecorderController.wireCaptureCallbacks`'s own reasoning: two chunks each
    /// spawned as their own `Task` can resume out of order across `sendMicChunk`'s own `await`,
    /// corrupting the sample offset the backend uses to place this take's audio. Feeding a stream
    /// synchronously from `onMicChunk` and draining it from one long-running task is what actually
    /// guarantees order, rather than merely hoping the scheduler preserves it.
    private var micChunkContinuation: AsyncStream<[Int16]>.Continuation?
    /// Same `nonisolated(unsafe)` discipline as `interruptionObserver` — `deinit` only ever calls
    /// `cancel()` on whatever this held, never anything that touches this actor's isolated state.
    private nonisolated(unsafe) var micChunkConsumerTask: Task<Void, Never>?

    init(requestFactory: PaiRequestFactory, authToken: @escaping @Sendable () -> String?, toasts: ToastCenter) {
        self.toasts = toasts
        // Its own notifier over its own audio engine, not `VoiceRecorderController`'s: only one
        // of the two engines is ever running, and a cue rendered through the idle one is a cue
        // nobody hears. The `FeedbackPolicy` inside is what keeps a bad patch of signal to a
        // handful of sounds rather than one per flap.
        let notifier = VoiceFeedbackNotifier(earcons: EarconPlayer(audioIO: audioIO))
        feedbackNotifier = notifier
        session = ComputerCallSession(
            dependencies: ComputerCallDependencies(
                makeTransport: { URLSessionVoiceSocketTransport() },
                socketURL: { try requestFactory.voiceSocketURL() },
                authToken: authToken,
                feedback: { event in MainActor.assumeIsolated { notifier.handle(event) } }
            ))

        let (chunkStream, continuation) = AsyncStream<[Int16]>.makeStream()
        micChunkContinuation = continuation
        micChunkConsumerTask = Task { [weak self] in
            for await samples in chunkStream {
                await self?.session.sendMicChunk(pcm16le: samples)
            }
        }
        audioIO.onMicChunk = { samples in
            continuation.yield(samples)
        }
        audioIO.onConfigurationChange = { [weak self] in
            Task { @MainActor [weak self] in self?.handleConfigurationChange() }
        }
        session.onAudioDown = { [weak self] ref, pcm in
            Task { @MainActor [weak self] in self?.play(ref: ref, pcm: pcm) }
        }
        session.onClearRequested = { [weak self] in
            Task { @MainActor [weak self] in self?.handleClearRequested() }
        }

        observeInterruptions()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        micChunkConsumerTask?.cancel()
    }

    /// `connectSession` connects straight into that Kai session's call mode rather than
    /// reaching Computer first — what the launcher's call tiles and a composer's own
    /// "Call this session" ask for.
    func start(connectSession: String? = nil) async {
        setupFailure = nil
        // One episode per call, so a drop announced during the last one cannot be updated in
        // place by this one — and so the per-cause dedup starts clean.
        feedbackNotifier.beginTake(id: "call-\(Int(Date().timeIntervalSince1970 * 1000))", subject: .call)
        guard await requestMicrophonePermission() else {
            setupFailure = "Microphone access is off — enable it in Settings to talk to Computer."
            return
        }
        do {
            try audioIO.start()
        } catch {
            setupFailure = "Couldn't start the microphone. Try again."
            return
        }
        await session.start(connectSession: connectSession)
        if let failure = session.lastStartFailure {
            setupFailure = failure.userMessage
            audioIO.stop()
        }
    }

    /// Whether a call is running right now — what the app-wide call bar and every door onto the
    /// voice screen read, so none of them re-derives it from a different field.
    var isLive: Bool { session.connectionState != .idle }

    func end() async {
        audioIO.stop()
        // The chunk stream is deliberately NOT finished here: this controller outlives any one
        // call, and a finished `AsyncStream` cannot be reopened — the next call would capture
        // audio into a consumer that had already returned, with nothing anywhere saying so.
        // `sendMicChunk` drops whatever arrives while the session is idle, and `audioIO.stop()`
        // means nothing arrives at all.
        pendingPlaybackChunks = 0
        isSpeaking = false
        await session.end()
    }

    /// Sends one of the controls the call's own spoken grammar also offers
    /// (`docs/VOICE_PROTOCOL.md`'s `command` frame). Only a bus a Kai session's call mode owns
    /// acts on these; Computer's own engine ignores them, so the caller gates on the face it is
    /// showing rather than this type second-guessing which engine is attached.
    func send(command: VoiceCallCommand) async {
        await session.send(command: command)
    }

    private func play(ref: Int, pcm: Data) {
        pendingPlaybackChunks += 1
        isSpeaking = true
        audioIO.play(pcm16le: pcm) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                pendingPlaybackChunks = max(0, pendingPlaybackChunks - 1)
                if pendingPlaybackChunks == 0 { isSpeaking = false }
                await session.notePlayed(ref: ref)
            }
        }
    }

    /// A barge-in: whatever was queued for playback is gone the instant this arrives
    /// (`docs/VOICE_PROTOCOL.md`'s `clear`), so nothing left playing means nothing left to call
    /// `isSpeaking` for either — the completion handlers those cleared buffers would have fired
    /// never will, since `AVAudioPlayerNode.stop()` drops them outright.
    private func handleClearRequested() {
        audioIO.clearPlayback()
        pendingPlaybackChunks = 0
        isSpeaking = false
    }

    /// The engine invalidated every tap and connection on itself — a route change, matching
    /// `MicrophoneCapture.onConfigurationChange`'s own doc comment. Rebuilding from scratch is
    /// safe here the same way `ComputerAudioIO.start()` already is for a fresh call: it never
    /// assumes prior state, only that the engine and session objects still exist. Ends the call
    /// rather than leaving it half-broken if the rebuild itself fails.
    private func handleConfigurationChange() {
        guard session.connectionState != .idle else { return }
        do {
            try audioIO.start()
        } catch {
            toasts.show("Lost the microphone — ending the call with Computer.")
            Task { await end() }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default: return false
        }
    }

    /// Mirrors `VoiceRecorderController.observeInterruptions()`, simplified: a call with
    /// Computer has no paused/resume state of its own to preserve — the system already took the
    /// microphone by the time `.began` fires, so the call ends rather than waiting to see whether
    /// `.ended` ever arrives.
    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: audioSession, queue: .main
        ) { [weak self] notification in
            guard
                let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                AVAudioSession.InterruptionType(rawValue: typeValue) == .began
            else { return }
            Task { @MainActor [weak self] in
                self?.toasts.show("Computer ended — something else needed the microphone.")
                await self?.end()
            }
        }
    }
}
