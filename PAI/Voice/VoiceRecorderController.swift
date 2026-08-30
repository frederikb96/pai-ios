import AVFoundation
import Foundation
import Observation
import PAIKit

/// Ties `PAIKit`'s `VoiceRecordingSession` (the tested decision core: state machine, wire
/// protocol, silence semantics, prefixing) to what only a real device can supply: microphone
/// capture, `AVAudioSession` configuration and interruption/permission handling, and where a
/// finished recording's bytes and metadata actually land.
///
/// 🚨 **One instance for the whole app, owned by `AppEnvironment.Connection`** — never one per
/// composer. A recorder that belongs to a view dies when the view does, so switching to another
/// screen, or opening the terminal, silently ends a take mid-sentence; and a take is exactly the
/// thing a person starts and then stops looking at. The microphone is a single exclusive resource
/// anyway, so one owner for it is also the honest model.
///
/// The take is therefore keyed by ``activeDraftKey`` rather than by whoever is on screen, and the
/// transcript is written into ``DraftStore`` as it arrives rather than into a view's own state —
/// that is what makes it survive both the view going away and the app being backgrounded, and what
/// puts it on Freddy's other clients at the same time.
///
/// Recording continues while the app is in the background or the screen is locked. That needs
/// three things agreeing: `UIBackgroundModes = audio`, an `AVAudioSession` that stays active, and
/// nothing tearing the capture down on `scenePhase` — the third being the one this type is
/// responsible for, by not being owned by anything with a lifecycle.
@MainActor
@Observable
final class VoiceRecorderController {
    enum SetupFailure: Equatable {
        case microphoneDenied
        case audioSessionFailed

        var userMessage: String {
            switch self {
            case .microphoneDenied: "Microphone access is off — enable it in Settings to record."
            case .audioSessionFailed: "Couldn't start the microphone. Try again."
            }
        }
    }

    private(set) var voiceSession: VoiceRecordingSession
    private(set) var isCapturing = false
    private(set) var setupFailure: SetupFailure?
    /// The bytes behind past recordings. The list itself belongs to `SettingsStore`, which is
    /// what the settings screen renders and what persists.
    private let recordingAudio: RecordingAudioLibrary

    var state: VoiceRecordingState { voiceSession.state }
    var isMuted: Bool { voiceSession.isMuted }
    var transcribedText: String { voiceSession.transcribedText }
    var lastStartFailure: VoiceStartFailure? { voiceSession.lastStartFailure }

    /// The session this take belongs to, or `nil` when nothing is being recorded. Set before the
    /// microphone opens and cleared only once the take's final text has been written, so a
    /// composer for a different session can always tell that the recorder is not its own.
    private(set) var activeDraftKey: String?
    /// Whatever was already in that session's draft when the take started. The live transcript is
    /// appended to it rather than replacing it, and it is what a take that transcribed nothing
    /// restores.
    private var preVoiceText = ""
    private var liveTextTask: Task<Void, Never>?
    /// Held for the whole of `start()`, which is `async` and therefore interleaves.
    ///
    /// 🚨 `voiceSession.state` does not leave `.idle` until well after `start()`'s first `await`,
    /// so for that entire window every `canStart` check — including the one behind the record
    /// button — still says yes. A second tap, or a tap in another session's composer, then enters
    /// `start()` again, takes `activeDraftKey` from the first caller and starts a second capture
    /// on the one `AVAudioEngine`. This is the only thing that closes that window, because it is
    /// the only state set before an `await` can hand control away.
    private var isStarting = false

    private let settingsStore: SettingsStore
    private let drafts: DraftStore
    private let apiClient: PaiApiClient
    private let capture = MicrophoneCapture()
    private let audioStorage = FileRecordingAudioStorage()
    private let audioSession = AVAudioSession.sharedInstance()

    /// Fixed the moment a take starts, not when it ends — both because `StreamingRecordingFile`
    /// needs its final path before the first sample arrives, and because a take's identity should
    /// be when it began, not roughly when it happened to stop.
    private var takeTimestampMs: Double?
    /// Audio actually sent (already resampled, muted windows zeroed to match what the wire
    /// carried) and the untouched hardware-rate capture — both written to disk as they arrive
    /// rather than held in memory for the whole take, which is what let a take killed near the
    /// end lose everything before it too. `nil` whenever the file could not even be opened, or
    /// (for `streamingRaw`) once the budget below is exceeded.
    private var streamingSent: StreamingRecordingFile?
    private var streamingRaw: StreamingRecordingFile?
    /// The rate `streamingRaw` was opened at — captured once, so a hardware rate change on resume
    /// (a Bluetooth headset reconnecting at a different rate than it dropped at, say) can be
    /// detected and raw capture stopped rather than writing samples a fixed WAV header disagrees
    /// with. The sent stream never has this problem: it is always resampled to the one rate
    /// `VoiceRecordingSession.transportSampleRateHz` fixed for the whole take.
    private var streamingRawSampleRate: Int?
    private var rawBudgetExceeded = false
    private static let rawBudgetSamples = 64 * 1024 * 1024 / 2

    private var peakAmplitude: Double = 0
    private var levelSum: Double = 0
    private var levelCount: Int = 0

    /// `VoiceRecordingSession` can end a take entirely on its own — a reconnect exhausting its
    /// attempts, a protocol error — with no call back into this type at all. Without something
    /// watching for that, `capture` would keep running the microphone into a socket that no
    /// longer exists, and the take would never reach `persistRecording()`. Polling, matching
    /// `ComposerBar.observeLiveTranscript`'s own established pattern for watching this same
    /// `@Observable` session from outside a SwiftUI view body.
    private var sessionWatcherTask: Task<Void, Never>?

    /// When a buffer last arrived from the microphone, and the watch that acts on its absence.
    ///
    /// 🚨 An `AVAudioEngine` tap can stop delivering buffers while `engine.isRunning` still
    /// reports `true`, so there is no state to inspect that would reveal it — the only symptom is
    /// silence, and silence is also what a quiet room produces. That is the shape of a take that
    /// dies the moment the app leaves the screen: nothing throws, nothing is notified, and the
    /// recording simply ends mid-sentence with a plausible file on disk.
    ///
    /// `AVAudioEngineConfigurationChange` covers the documented cause and is handled directly.
    /// This covers the rest, including whatever is not on that list, because the failure is
    /// detectable without knowing its cause: audio was flowing, and now it is not.
    private var lastChunkAt: Date?
    private var captureWatchdogTask: Task<Void, Never>?
    private var captureRestartAttempts = 0
    private var lastCaptureRestartAt: Date?
    /// Comfortably longer than the ~100ms cadence chunks actually arrive at, so a scheduling
    /// hiccup or a busy main actor cannot be mistaken for a dead microphone.
    private static let captureStallSeconds: TimeInterval = 4
    /// One restart is a route change settling; a second failing straight away is not something
    /// retrying will fix, and continuing to look live while recording nothing is the worst
    /// outcome available. The budget is per *episode*, not per take — see `recoveryHoldSeconds`.
    private static let maxCaptureRestarts = 2
    /// How long capture has to run cleanly before a restart stops counting against the budget.
    /// Without this the budget is spent for the life of the take, so an hour-long recording that
    /// survived two route changes in its first minute would end at the third — even though every
    /// recovery worked. Two failures in quick succession is the signal; two an hour apart is
    /// simply a long recording in a moving world.
    private static let recoveryHoldSeconds: TimeInterval = 60

    /// `nonisolated(unsafe)` so `deinit` — which is nonisolated — can unregister it. Written
    /// once on the main actor during setup and read once at deallocation, when nothing else holds
    /// a reference, so there is no concurrent access for the isolation to protect.
    private nonisolated(unsafe) var interruptionObserver: NSObjectProtocol?

    init(apiClient: PaiApiClient, settingsStore: SettingsStore, drafts: DraftStore) {
        self.apiClient = apiClient
        self.settingsStore = settingsStore
        self.drafts = drafts
        self.recordingAudio = RecordingAudioLibrary(storage: audioStorage)

        voiceSession = VoiceRecordingSession(
            dependencies: VoiceRecordingDependencies(
                mintToken: { purpose in try await apiClient.mintVoiceToken(purpose: purpose) },
                makeRealtimeTransport: { URLSessionVoiceRealtimeTransport() },
                // The session is `@MainActor`, so it only ever calls this from the main actor —
                // but the dependency's type cannot say so. Asserting the isolation we already have
                // beats making the settings read `nonisolated`, which it genuinely is not.
                settings: { MainActor.assumeIsolated { Self.voiceSettings(from: settingsStore) } }
            )
        )

        // The list evicts; the audio follows. This is the only thing that deletes a blob, so a
        // recording's bytes cannot outlive its metadata.
        let audio = recordingAudio
        settingsStore.onRecordingEvicted = { meta in
            Task { await audio.delete(id: meta.id) }
        }

        observeInterruptions()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    var canStart: Bool {
        !isStarting && voiceSession.canStart && settingsStore.elevenLabsKey.status?.set != false
    }

    // MARK: - Start / stop

    /// `draftKey` names where the live transcript is written as it arrives — a session id for the
    /// chat composer. `nil` for a caller that keeps its own composer text outside `DraftStore`
    /// (the new-session sheet, deliberately); that caller reads ``transcribedText`` itself and
    /// nothing is written anywhere on its behalf.
    ///
    /// `preText` is what is already in the field; the transcript is appended to it rather than
    /// replacing it. Passed in rather than read from `drafts` here so the caller's own idea of
    /// what is in the field — which may include an edit still inside the flush debounce — wins.
    func start(draftKey: String?, preText: String) async {
        guard !isStarting, voiceSession.canStart else { return }
        isStarting = true
        defer { isStarting = false }
        setupFailure = nil
        activeDraftKey = draftKey
        preVoiceText = preText

        // Both failures below happen before a take exists, so the claim on `activeDraftKey` has
        // to be released here — left set, the recorder would report a recording in progress
        // forever and every composer would refuse to start one.
        guard await requestMicrophonePermission() else {
            setupFailure = .microphoneDenied
            releaseTakeWithoutText()
            return
        }
        do {
            try configureAudioSession()
        } catch {
            setupFailure = .audioSessionFailed
            releaseTakeWithoutText()
            return
        }

        let timestampMs = Date().timeIntervalSince1970 * 1000
        takeTimestampMs = timestampMs
        let hardwareRate = capture.hardwareSampleRate
        let transportRate = VoiceAudioRatePolicy.transportRate(hardwareRate: hardwareRate)
        openStreamingFiles(
            id: RecordingMeta.id(forTimestampMs: timestampMs), sentRate: transportRate, rawRate: hardwareRate)
        wireCaptureCallbacks()

        let startTask = Task { await voiceSession.start(hardwareSampleRate: hardwareRate) }
        // `VoiceRecordingSession.start()` flips `state` to `.connecting` synchronously, before its
        // first `await` — waiting for that to become observable (rather than a fixed delay) is
        // what lets capture begin the moment the session can accept chunks, so the pre-connect
        // buffer actually protects the start of the take instead of racing it.
        var guardIterations = 0
        while voiceSession.state == .idle && guardIterations < 200 {
            await Task.yield()
            guardIterations += 1
        }

        do {
            try capture.start(targetSampleRate: transportRate)
            isCapturing = true
            beginCaptureWatchdog()
            sessionWatcherTask?.cancel()
            sessionWatcherTask = Task { [weak self] in await self?.watchForSessionEndingOnItsOwn() }
            liveTextTask?.cancel()
            liveTextTask = Task { [weak self] in await self?.streamLiveTextIntoDraft() }
        } catch {
            // `openStreamingFiles` above already opened this take's files — without persisting
            // (which cleans up on a zero-duration take, same as any other empty take), the open
            // handle and its stub files on disk would just be abandoned here.
            setupFailure = .audioSessionFailed
            capture.stop()
            await voiceSession.stop(reason: .error)
            await persistRecording()
        }
        await startTask.value
    }

    // MARK: - Live transcript

    /// Streams the growing transcript into the session's draft while a take runs.
    ///
    /// 🚨 **Into the draft, not into a view's own text state.** The web writes the live partial
    /// through its draft store (`MessageInput.tsx`'s `setText` → `setDraft`) and this app once did
    /// not: it wrote a `@State` string the composer's own ten-second draft poll then overwrote
    /// with the pre-recording text, so a pause in speaking made everything transcribed so far
    /// vanish and the next word brought it all back. Writing here is also what keeps a take
    /// meaningful after the composer is gone: the text is already somewhere that outlives it.
    ///
    /// Polling, matching the pattern used to watch this same `@Observable` session elsewhere.
    private func streamLiveTextIntoDraft() async {
        var lastPartial = ""
        while !Task.isCancelled, voiceSession.state != .idle {
            let partial = voiceSession.transcribedText
            if partial != lastPartial, let draftKey = activeDraftKey {
                lastPartial = partial
                drafts.setDraftText(key: draftKey, text: Self.composeLiveText(pre: preVoiceText, partial: partial))
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// `pre` and the running partial, joined the way the composer used to join them — the
    /// `stt-rec: ` prefix is written once and only the text after it keeps growing, matching
    /// `VoiceRecordingSession`'s own contract for `transcribedText` against `result.prefixedText`.
    static func composeLiveText(pre: String, partial: String) -> String {
        guard !partial.isEmpty else { return pre }
        let prefixed = "\(VoiceRecordingResult.sttPrefix)\(partial)"
        return pre.isEmpty ? prefixed : "\(pre) \(prefixed)"
    }

    /// The one place a finished take's text reaches the draft, called from `persistRecording()`
    /// because that is the single funnel every ending goes through — the user's tap, silence
    /// detection, a lost connection, an interruption nothing could resume. Wiring this to the tap
    /// alone is what left the other three endings writing nothing at all.
    private func finishLiveText() {
        liveTextTask?.cancel()
        liveTextTask = nil
        defer {
            activeDraftKey = nil
            preVoiceText = ""
        }
        // A caller driving its own composer text passes no key; there is nothing to write, but
        // the claim on the recorder still has to be released, which is what the `defer` is for.
        guard let draftKey = activeDraftKey else { return }
        let prefixed = voiceSession.result.prefixedText
        let combined =
            prefixed.isEmpty
            ? preVoiceText
            : (preVoiceText.isEmpty ? prefixed : "\(preVoiceText) \(prefixed)")
        drafts.setDraftText(key: draftKey, text: combined)
    }

    /// Gives up the take without touching the draft — for the failures that happen before any
    /// audio was captured, where the field should read exactly as it did before the tap.
    private func releaseTakeWithoutText() {
        liveTextTask?.cancel()
        liveTextTask = nil
        activeDraftKey = nil
        preVoiceText = ""
    }

    /// Notices a take the session ended by itself — `isCapturing` is the signal that neither
    /// `stop()` nor `giveUpAfterInterruption()` has already run this exact cleanup, both of which
    /// set it `false` before the state transition that would otherwise trigger this too.
    private func watchForSessionEndingOnItsOwn() async {
        while !Task.isCancelled {
            if voiceSession.state == .idle {
                if isCapturing { await handleSessionEndedOnItsOwn() }
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func handleSessionEndedOnItsOwn() async {
        capture.stop()
        isCapturing = false
        endCaptureWatchdog()
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        await persistRecording()
    }

    func toggleMute() {
        voiceSession.toggleMute()
    }

    /// A fresh single-use batch token for re-transcribing a past recording — minted here rather
    /// than cached anywhere, the same discipline the realtime path follows: caching a single-use
    /// token is a bug, not an optimisation.
    func mintBatchToken() async throws -> String {
        try await apiClient.mintVoiceToken(purpose: .batch).token
    }

    /// Stops the take, persists the recording (audio + metadata), and returns the composer-ready
    /// prefixed text for the caller to insert.
    @discardableResult
    func stop() async -> String {
        guard isCapturing || voiceSession.state != .idle else { return "" }
        capture.stop()
        isCapturing = false
        endCaptureWatchdog()
        await voiceSession.stop(reason: .user)
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)

        await persistRecording()
        return voiceSession.result.prefixedText
    }

    // MARK: - Permission

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

    // MARK: - Audio session

    /// `.playAndRecord` rather than `.record`, and active for the whole take — that pairing plus
    /// the `audio` background mode is what keeps the microphone running once the app leaves the
    /// screen. `.measurement` turns off the system's own gain and noise processing, which is
    /// right when the audio is going to a transcriber rather than to a listener.
    ///
    /// `.overrideMutedMicrophoneInterruption` is the one that is not obvious: without it, the
    /// system *interrupts the session* whenever the built-in microphone is muted by hardware,
    /// which ends a take rather than producing silence in it. For a recorder that is expected to
    /// run unattended in the user's pocket, silence is the far better failure.
    private func configureAudioSession() throws {
        try audioSession.setCategory(
            .playAndRecord, mode: .measurement,
            options: [.duckOthers, .allowBluetooth, .overrideMutedMicrophoneInterruption])
        try audioSession.setActive(true)
    }

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: audioSession, queue: .main
        ) { [weak self] notification in
            guard
                let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else { return }
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            let shouldResume =
                optionsValue.map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
            Task { @MainActor [weak self] in
                switch type {
                case .began: self?.handleInterruptionBegan()
                case .ended: await self?.handleInterruptionEnded(shouldResume: shouldResume)
                @unknown default: break
                }
            }
        }
    }

    /// The system has already taken the microphone by the time this fires — capture must stop
    /// regardless of what happens next. The take itself only pauses: `PAIKit`'s
    /// `VoiceRecordingSession` keeps the socket and everything transcribed so far, waiting for
    /// `handleInterruptionEnded` to decide whether it can continue.
    private func handleInterruptionBegan() {
        guard isCapturing else { return }
        capture.stop()
        isCapturing = false
        endCaptureWatchdog()
        voiceSession.pauseForInterruption()
    }

    /// `shouldResume == false` is documented by Apple for exactly the case where another app
    /// claimed the session for itself — a take that cannot get the microphone back must end
    /// rather than sit paused forever with nothing able to un-pause it.
    private func handleInterruptionEnded(shouldResume: Bool) async {
        guard voiceSession.state == .paused else { return }
        guard shouldResume else {
            await giveUpAfterInterruption()
            return
        }
        do {
            try configureAudioSession()
            // The same target the take started with, not whatever the hardware's own rate is
            // now — a route change mid-call (an AirPod reconnecting, say) must not change what
            // the socket already agreed to receive.
            try capture.start(targetSampleRate: voiceSession.transportSampleRateHz)
            isCapturing = true
            beginCaptureWatchdog()
            checkRawStreamStillMatchesHardwareRate()
            voiceSession.resumeAfterInterruption()
        } catch {
            await giveUpAfterInterruption()
        }
    }

    private func giveUpAfterInterruption() async {
        await voiceSession.stop(reason: .interrupted)
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        await persistRecording()
        await VoiceInterruptionNotifier.notify(reason: .interrupted)
    }

    /// The raw stream is fixed at the hardware rate it was opened with; if the route changed
    /// while paused, writing more samples into it would silently disagree with the WAV header
    /// already on disk. The sent stream has no such problem — it stays at the transport rate for
    /// the whole take regardless of hardware changes, per `AVAudioConverter`'s job.
    private func checkRawStreamStillMatchesHardwareRate() {
        guard let streamingRawSampleRate, streamingRawSampleRate != capture.hardwareSampleRate else { return }
        streamingRaw?.finalize()
        streamingRaw = nil
    }

    // MARK: - Capture wiring

    private func openStreamingFiles(id: String, sentRate: Int, rawRate: Int) {
        rawBudgetExceeded = false
        peakAmplitude = 0
        levelSum = 0
        levelCount = 0
        streamingSent = StreamingRecordingFile(url: audioStorage.sentURL(id: id), sampleRate: sentRate)
        streamingRaw = StreamingRecordingFile(url: audioStorage.rawURL(id: id), sampleRate: rawRate)
        streamingRawSampleRate = rawRate
    }

    private func wireCaptureCallbacks() {
        capture.onConfigurationChange = { [weak self] in
            Task { @MainActor [weak self] in await self?.restartCapture() }
        }
        capture.onLevel = { [weak self] rms in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.voiceSession.ingestLevel(rms: rms)
                self.peakAmplitude = max(self.peakAmplitude, rms)
                self.levelSum += rms
                self.levelCount += 1
            }
        }
        capture.onChunk = { [weak self] samples in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastChunkAt = Date()
                // Mirrors what `VoiceRecordingSession.ingestAudioChunk` actually transmits when
                // muted — the socket receives zeroes, so the saved "sent" recording should too,
                // rather than silently disagreeing with what ElevenLabs was given.
                let effective = self.voiceSession.isMuted ? [Int16](repeating: 0, count: samples.count) : samples
                self.streamingSent?.append(pcm16le: effective)
                await self.voiceSession.ingestAudioChunk(pcm16le: samples)
            }
        }
        capture.onRawChunk = { [weak self] samples in
            Task { @MainActor [weak self] in
                guard let self, !self.rawBudgetExceeded, let streamingRaw = self.streamingRaw else { return }
                if streamingRaw.sampleCount + samples.count > Self.rawBudgetSamples {
                    // Stops taking more, but keeps what was already captured — strictly better
                    // than the all-or-nothing discard a fixed in-memory buffer used to force,
                    // and the raw copy was always a diagnostic nicety, never the transcript.
                    self.rawBudgetExceeded = true
                    return
                }
                streamingRaw.append(pcm16le: samples)
            }
        }
    }

    // MARK: - Capture watchdog

    private func beginCaptureWatchdog() {
        captureWatchdogTask?.cancel()
        lastChunkAt = Date()
        captureRestartAttempts = 0
        lastCaptureRestartAt = nil
        captureWatchdogTask = Task { [weak self] in await self?.watchForSilentMicrophone() }
    }

    private func endCaptureWatchdog() {
        captureWatchdogTask?.cancel()
        captureWatchdogTask = nil
        lastChunkAt = nil
    }

    /// Only ever acts while `isCapturing` — a take paused by an interruption is *meant* to be
    /// delivering nothing, and treating that as a stall would fight the resume path for the
    /// microphone.
    private func watchForSilentMicrophone() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, isCapturing, let last = lastChunkAt else { continue }
            let now = Date()
            guard now.timeIntervalSince(last) > Self.captureStallSeconds else {
                if let restarted = lastCaptureRestartAt, now.timeIntervalSince(restarted) > Self.recoveryHoldSeconds {
                    captureRestartAttempts = 0
                    lastCaptureRestartAt = nil
                }
                continue
            }
            await recoverSilentMicrophone()
        }
    }

    private func recoverSilentMicrophone() async {
        guard captureRestartAttempts < Self.maxCaptureRestarts else {
            // Out of attempts. Ending the take is what makes this recoverable: the audio captured
            // so far is already on disk, and Freddy is told rather than discovering an hour later
            // that a recording he believed was running captured nothing.
            //
            // 🚨 `isCapturing` first and `endCaptureWatchdog()` last, because this runs *inside*
            // the watchdog's own task: cancelling it up front would leave every `await` below
            // running in a cancelled task, and the first one that honours cancellation would
            // abandon the teardown half-done. Clearing `isCapturing` is what actually stops the
            // loop from acting again in the meantime.
            isCapturing = false
            capture.stop()
            await voiceSession.stop(reason: .error)
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            await persistRecording()
            await VoiceInterruptionNotifier.notify(reason: .error)
            endCaptureWatchdog()
            return
        }
        captureRestartAttempts += 1
        lastCaptureRestartAt = Date()
        lastChunkAt = Date()
        await restartCapture()
    }

    /// The engine stopped itself and invalidated its own graph — see
    /// `MicrophoneCapture.onConfigurationChange`. Restarting is the only way back; the take, the
    /// socket and everything transcribed so far are untouched by this and continue.
    ///
    /// Deliberately at the rate the take negotiated at the start rather than the hardware's rate
    /// now: whatever changed the configuration may well have changed the input rate, and the
    /// socket on the other end already agreed what it is receiving. Same rule as resuming after
    /// an interruption.
    ///
    /// A restart that fails ends the take rather than leaving it looking live with a dead
    /// microphone — the one outcome worse than stopping is appearing not to have.
    private func restartCapture() async {
        guard isCapturing else { return }
        capture.stop()
        do {
            // `capture.start` re-reads the input node's own format, so the tap is reinstalled
            // against whatever the hardware is now — which is the half of this that matters, and
            // the half a restart at a remembered format would get wrong.
            try capture.start(targetSampleRate: voiceSession.transportSampleRateHz)
            lastChunkAt = Date()
            checkRawStreamStillMatchesHardwareRate()
        } catch {
            // Same ordering rule as `recoverSilentMicrophone`'s give-up branch, and for the same
            // reason: one of this method's callers is the watchdog task itself.
            isCapturing = false
            await voiceSession.stop(reason: .error)
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            await persistRecording()
            await VoiceInterruptionNotifier.notify(reason: .error)
            endCaptureWatchdog()
        }
    }

    // MARK: - Persisting a finished take

    private func persistRecording() async {
        // Before any of the early returns below: a take that produced no audio worth keeping
        // still has to hand its text back (or put the field back the way it was), and every way
        // a take can end arrives here.
        finishLiveText()

        let result = voiceSession.result
        let sent = streamingSent
        let raw = streamingRaw
        streamingSent = nil
        streamingRaw = nil
        sent?.finalize()
        raw?.finalize()

        guard let timestampMs = takeTimestampMs else { return }
        takeTimestampMs = nil
        let id = RecordingMeta.id(forTimestampMs: timestampMs)

        guard result.durationMs > 0, sent?.hasData == true else {
            // Nothing worth keeping — `start()` already opened files for this id, so clean up the
            // stubs rather than leaving 44-byte orphans behind.
            await audioStorage.delete(id: id)
            return
        }
        let rawKept = raw?.hasData == true
        if !rawKept {
            audioStorage.removeRaw(id: id)
        }

        let settings = Self.voiceSettings(from: settingsStore)
        let averageLevel = levelCount > 0 ? levelSum / Double(levelCount) : 0
        let mic = MicDiagnostics(
            label: currentInputLabel(), trackSampleRate: Double(capture.hardwareSampleRate),
            contextSampleRate: Double(capture.hardwareSampleRate), channelCount: 1,
            echoCancellation: nil, noiseSuppression: nil, autoGainControl: nil, userAgent: "iOS"
        )
        let meta = RecordingMeta(
            timestampMs: timestampMs,
            durationMs: Double(result.durationMs),
            sampleRate: Double(result.sampleRate),
            rawSampleRate: rawKept ? streamingRawSampleRate.map(Double.init) : nil,
            mic: mic,
            rawStored: rawKept,
            endedBy: result.endedBy,
            silence: SilenceMeta(
                enabled: settings.silenceDetectionEnabled, threshold: settings.silenceThreshold,
                durationMs: Double(settings.silenceDurationMs), triggered: result.endedBy == .silence
            ),
            stt: SttMeta(
                model: VoiceRealtimeProtocol.modelId, language: settings.sttLanguage.rawValue,
                vadSilenceSecs: Double(VoiceRealtimeProtocol.vadSilenceThresholdSecs) ?? 1.5,
                vadThreshold: Double(VoiceRealtimeProtocol.vadThreshold) ?? 0.4
            ),
            transcript: result.text.isEmpty ? nil : result.text,
            levels: LevelStats(
                peak: peakAmplitude, rms: averageLevel, clippedSamples: 0, totalSamples: sent?.sampleCount ?? 0
            ),
            narrowband: result.narrowband,
            startup: nil,
            mutedMs: result.mutedMs > 0 ? Double(result.mutedMs) : nil
        )
        settingsStore.saveRecording(meta)

        if result.endedBy == .connectionLost || result.endedBy == .error {
            await VoiceInterruptionNotifier.notify(reason: result.endedBy)
        }
    }

    private func currentInputLabel() -> String {
        audioSession.currentRoute.inputs.first?.portName ?? "Microphone"
    }

    // MARK: - Settings mapping

    /// `SettingsStore` persists `SttLanguage` (this app's own enum, deliberately with no
    /// provider-fallback case); `VoiceRecordingSession` speaks `VoiceSettings.Language` (the
    /// package's port of the same three web values). Same three cases, two independent enums —
    /// this is the one place that needs to know that.
    private static func voiceSettings(from settingsStore: SettingsStore) -> VoiceSettings {
        let language: VoiceSettings.Language =
            switch settingsStore.sttLanguage {
            case .auto: .auto
            case .en: .en
            case .de: .de
            }
        return VoiceSettings(
            sttLanguage: language,
            micDeviceId: settingsStore.micDeviceId,
            silenceDetectionEnabled: settingsStore.silenceDetectionEnabled,
            silenceThreshold: settingsStore.silenceThreshold,
            silenceDurationMs: Int(settingsStore.silenceDurationMs)
        )
    }
}
