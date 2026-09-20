import AVFoundation
import Foundation
import Observation
import PAIKit

/// Holds the app-wide `ConnectionHealth` machine behind a reference, so the two
/// `VoiceRecordingDependencies` closures `VoiceRecorderController.init` builds can share a live,
/// mutable handle to it without capturing `self` — which is not yet a valid capture target while
/// `init` is still assigning `voiceSession`, the very property those closures configure. Every
/// access goes through `MainActor.assumeIsolated`, matching every other dependency closure in this
/// file: nothing here promises thread safety of its own, because nothing here needs to.
private final class ConnectionHealthBox: @unchecked Sendable {
    var value = ConnectionHealth()
}

/// Ties `PAIKit`'s `VoiceUplinkSession` (the tested decision core: connect/reconnect, the ack
/// watermark, liveness) to what only a real device can supply: microphone capture, `AVAudioSession`
/// configuration and interruption/permission handling, and where a finished recording's bytes and
/// metadata actually land.
///
/// The recorder and the uplink are deliberately two different things sharing one class: capture
/// (`MicrophoneCapture` → `StreamingRecordingFile`) never stops for a network reason and has no
/// idea a backend exists at all; `voiceSession` is the only thing that does, and its own state
/// (`.reconnecting`, a dropped socket) never pauses the durable file underneath it. Freddy's own
/// framing: "iOS doesn't even know that there is another module" — true of the recorder half, and
/// this type is what keeps it true by never letting a connection problem reach `capture` or
/// `streamingSent`/`streamingRaw`.
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
        /// Free space is below `FileRecordingAudioStorage.minimumFreeBytes` — refusing to start is
        /// what keeps a take from ever running with no buffer under it, which is the exact failure
        /// the durable pipeline exists to rule out.
        case insufficientStorage

        var userMessage: String {
            switch self {
            case .microphoneDenied: "Microphone access is off — enable it in Settings to record."
            case .audioSessionFailed: "Couldn't start the microphone. Try again."
            case .insufficientStorage: "Not enough space to record safely. Free up some storage first."
            }
        }
    }

    /// One port `AVAudioSession` offers as an input — the platform's equivalent of the web's
    /// `MediaDeviceInfo`, minus the name-hiding: iOS names every port whether or not the mic has
    /// ever been granted, so there is no `useAudioInputs.ts`-style "reveal names" step here.
    struct MicrophoneOption: Identifiable, Equatable, Sendable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    private(set) var voiceSession: VoiceUplinkSession
    private(set) var isCapturing = false
    private(set) var setupFailure: SetupFailure?
    /// The bytes behind past recordings. The list itself belongs to `SettingsStore`, which is
    /// what the settings screen renders and what persists.
    private let recordingAudio: RecordingAudioLibrary
    /// Refreshed on every `AVAudioSession.routeChangeNotification`, matching the web's
    /// `useAudioInputs` re-reading its list on the `devicechange` event — plugging in a headset
    /// while the picker is open should offer it immediately.
    private(set) var availableMicrophones: [MicrophoneOption] = []

    var state: VoiceRecordingState { voiceSession.state }
    var isMuted: Bool { voiceSession.isMuted }
    var lastStartFailure: VoiceUplinkStartFailure? { voiceSession.lastStartFailure }
    /// The uplink's own last `notice`, for a composer that wants to say *why* transcription is
    /// degraded rather than only that it is — `nil` once a fresh take starts.
    var lastNotice: (severity: String, code: String, text: String)? { voiceSession.lastNotice }

    /// The session this take belongs to, or `nil` when nothing is being recorded. Set before the
    /// microphone opens and cleared only once the take's final text has been written, so a
    /// composer for a different session can always tell that the recorder is not its own.
    private(set) var activeDraftKey: String?
    /// Whatever was already in that session's draft when the take started. The live transcript is
    /// appended to it rather than replacing it, and it is what a take that transcribed nothing
    /// restores.
    private var preVoiceText = ""
    /// `true` for the whole of a take started by `startOfflineRecording(name:)` — never touches
    /// `voiceSession` at all (no draft, nothing to dictate into, nothing to send live), so
    /// `persistRecording()` reads this to know its duration must come from the captured samples
    /// rather than from the uplink's own wall-clock `result`, which was never started.
    private(set) var isRecordingOffline = false
    /// The name given at `startOfflineRecording(name:)`, carried through to the `RecordingMeta`
    /// `persistRecording()` writes — there is nowhere else to hold it between the two, since an
    /// offline take has no draft of its own to stash it in.
    private var pendingOfflineName: String?
    private var liveTextTask: Task<Void, Never>?
    /// One ordered consumer for every chunk `MicrophoneCapture` delivers — see
    /// `wireCaptureCallbacks()`'s own comment for why this exists instead of one `Task` per chunk.
    private var chunkContinuation: AsyncStream<[Int16]>.Continuation?
    private var chunkConsumerTask: Task<Void, Never>?
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
    private let toasts: ToastCenter
    private let capture = MicrophoneCapture()
    private let audioStorage = FileRecordingAudioStorage()
    private let audioSession = AVAudioSession.sharedInstance()

    // MARK: - Durable pipeline

    /// Fed by `NetworkPathObserver` and by `VoiceRecordingSession`'s own `connectionEvent` hook —
    /// one machine, app-wide, so it exists at launch (before any take has ever run) and keeps its
    /// view of the network path across takes rather than distrusting a link that was fine a
    /// second ago just because the previous take ended. A reference-typed box, not a plain
    /// `ConnectionHealth` property, because the dependency closures built in `init` need a live,
    /// mutable handle before `self` is a valid capture target — see `init`'s own comment.
    private let connectionHealthBox: ConnectionHealthBox
    private let pathObserver = NetworkPathObserver()
    private let earconPlayer: EarconPlayer
    private let feedbackNotifier: VoiceFeedbackNotifier
    /// The active take's own ledger, kept in memory between disk writes so the backfill loop and
    /// the ledger-write loop below never have to re-read what the other just wrote. `nil` while
    /// idle, and for every take that is not the one currently running — those are read from disk.
    private var activeLedger: TranscriptLedger?
    private var ledgerTask: Task<Void, Never>?
    /// One backfill loop per take still owed a gap — the active take's, and any take
    /// `reconcileTakes()` found still incomplete at launch. Keyed so a second call for a take
    /// already being worked is a no-op rather than a duplicate loop racing itself.
    private var backfillTasks: [String: Task<Void, Never>] = [:]
    private static let backfillPollSeconds: TimeInterval = 3

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
    /// The rate this take actually negotiated and whether that rate is narrowband — set once at
    /// `start()`, read back by `persistRecording()`. `VoiceUplinkSession` has no opinion on either
    /// (unlike the ElevenLabs-era session, which carried its own connection's rate): both are
    /// properties of the hardware route at the moment capture began, never of the socket.
    private var currentTransportRateHz = 0
    private var currentNarrowband = false

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
    /// The most recent buffer's own RMS, `0...1` — what the volume overlay draws its waveform
    /// from. Updated at the same ~100ms cadence buffers actually arrive at; nothing here re-taps
    /// the microphone or runs a second `AnalyserNode`-equivalent.
    private(set) var currentLevel: Double = 0
    /// What the volume overlay actually renders — see `MicrophoneHealthState`'s own doc comment
    /// for why "no buffers arriving" is never derived from amplitude. `.notHearing` while nothing
    /// is even recording is meaningless to a caller that already checks `state != .idle` first.
    var microphoneHealth: MicrophoneHealthState {
        guard isCapturing else { return .quiet }
        if let lastChunkAt, Date().timeIntervalSince(lastChunkAt) > Self.captureStallSeconds {
            return .notHearing
        }
        return currentLevel > MicrophoneHealthState.quietFloor ? .hearing(level: currentLevel) : .quiet
    }
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
    /// Same discipline as `interruptionObserver`, for `AVAudioSession.routeChangeNotification`.
    private nonisolated(unsafe) var routeChangeObserver: NSObjectProtocol?

    init(
        apiClient: PaiApiClient, requestFactory: PaiRequestFactory, authToken: @escaping @Sendable () -> String?,
        settingsStore: SettingsStore, drafts: DraftStore, toasts: ToastCenter
    ) {
        self.apiClient = apiClient
        self.settingsStore = settingsStore
        self.drafts = drafts
        self.toasts = toasts
        self.recordingAudio = RecordingAudioLibrary(storage: audioStorage)

        let earconPlayer = EarconPlayer(capture: capture)
        let feedbackNotifier = VoiceFeedbackNotifier(earcons: earconPlayer)
        self.earconPlayer = earconPlayer
        self.feedbackNotifier = feedbackNotifier
        // A local, not `self.connectionHealthBox`, on purpose: `voiceSession` below is the
        // property this whole initializer is still building, so nothing here may capture `self` —
        // the same reason `settings` captures the `settingsStore` parameter directly rather than
        // `self.settingsStore`. The box is assigned to the stored property right after.
        let connectionHealthBox = ConnectionHealthBox()
        self.connectionHealthBox = connectionHealthBox

        voiceSession = VoiceUplinkSession(
            dependencies: VoiceUplinkDependencies(
                makeTransport: { URLSessionVoiceSocketTransport() },
                socketURL: { try requestFactory.voiceSocketURL() },
                authToken: authToken,
                feedback: { event in MainActor.assumeIsolated { feedbackNotifier.handle(event) } },
                connectionEvent: { event in
                    MainActor.assumeIsolated {
                        Self.applyConnectionHealthEvent(event, box: connectionHealthBox, notifier: feedbackNotifier)
                    }
                }
            )
        )

        // The list evicts; the audio follows. This is the only thing that deletes a blob, so a
        // recording's bytes cannot outlive its metadata.
        let audio = recordingAudio
        settingsStore.onRecordingEvicted = { meta in
            Task { await audio.delete(id: meta.id) }
        }

        observeInterruptions()
        refreshAvailableMicrophones()
        observeRouteChanges()
        // Every stored property has a value now — `self` is safe to capture, which
        // `wireNetworkPathObserver()` does.
        wireNetworkPathObserver()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
        pathObserver.stop()
    }

    var canStart: Bool { !isStarting && !isRecordingOffline && voiceSession.canStart }

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
        guard !isStarting, !isRecordingOffline, voiceSession.canStart else { return }
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
        // A take with no room under it is exactly the failure this whole design exists to rule
        // out — refusing before the first sample is captured is the only point a "not enough
        // space" message is still useful rather than a recording that silently stops partway.
        if let free = audioStorage.freeDiskSpaceBytes(), free < FileRecordingAudioStorage.minimumFreeBytes {
            setupFailure = .insufficientStorage
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
        let takeId = RecordingMeta.id(forTimestampMs: timestampMs)
        feedbackNotifier.beginTake(id: takeId)
        AppVoiceDiagnosticsLog.shared.log(.info, .mode, "microphone take started")
        let hardwareRate = capture.hardwareSampleRate
        let transportRate = VoiceAudioRatePolicy.transportRate(hardwareRate: hardwareRate)
        // Told once, at the start of the take — matching the web's `startRecording`, which warns
        // here rather than waiting for `RecordingsSheet` to show it after the fact. Nothing
        // downstream can undo a narrowband route; the only useful move is naming what is costing
        // the accuracy while there is still time to disconnect it.
        if VoiceAudioRatePolicy.isNarrowband(rate: transportRate) {
            toasts.show(
                "Mic is narrowband (\(transportRate / 1000) kHz, \(currentInputLabel())) — "
                    + "transcription will be poor. Disconnect the headset to use the phone mic.")
        }
        currentTransportRateHz = transportRate
        currentNarrowband = VoiceAudioRatePolicy.isNarrowband(rate: transportRate)
        openStreamingFiles(id: takeId, sentRate: transportRate, rawRate: hardwareRate)
        wireCaptureCallbacks()

        let startTask = Task { await voiceSession.start(draftKey: draftKey, takeId: takeId) }
        // `VoiceUplinkSession.start()` flips `state` to `.connecting` synchronously, before its
        // first `await` — waiting for that to become observable (rather than a fixed delay) is
        // what lets capture begin the moment the session can accept chunks, so nothing captured
        // in the first instant is lost even though the socket is not yet open.
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
            activeLedger = TranscriptLedger(
                takeId: takeId, mode: .microphone, sampleRate: transportRate, draftKey: draftKey, preText: preText)
            ledgerTask?.cancel()
            ledgerTask = Task { [weak self] in await self?.runLedgerLoop(takeId: takeId) }
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

    /// Records to a local file only — no draft, no uplink, nothing transcribed until Freddy asks
    /// for it from the recordings list. What Quick Actions' note-taking-style tile starts: a
    /// meeting, a thought while driving, anything meant to be reviewed later rather than typed
    /// into a session right now.
    ///
    /// Deliberately does not touch `voiceSession` at all — an offline recording has nowhere to
    /// send audio and nothing to dictate into, so there is no uplink to start, no gate to open, no
    /// backend connection required. `persistRecording()` reads `isRecordingOffline` to know its
    /// duration has to come from the captured samples instead of the uplink's own wall-clock
    /// `result`, which stays untouched for the whole of this take.
    func startOfflineRecording(name: String) async {
        guard !isStarting, !isRecordingOffline, voiceSession.canStart else { return }
        isStarting = true
        defer { isStarting = false }
        setupFailure = nil

        guard await requestMicrophonePermission() else {
            setupFailure = .microphoneDenied
            return
        }
        if let free = audioStorage.freeDiskSpaceBytes(), free < FileRecordingAudioStorage.minimumFreeBytes {
            setupFailure = .insufficientStorage
            return
        }
        do {
            try configureAudioSession()
        } catch {
            setupFailure = .audioSessionFailed
            return
        }

        let timestampMs = Date().timeIntervalSince1970 * 1000
        takeTimestampMs = timestampMs
        isRecordingOffline = true
        pendingOfflineName = name
        feedbackNotifier.beginTake(id: RecordingMeta.id(forTimestampMs: timestampMs))
        AppVoiceDiagnosticsLog.shared.log(.info, .mode, "offline take started")
        let hardwareRate = capture.hardwareSampleRate
        let transportRate = VoiceAudioRatePolicy.transportRate(hardwareRate: hardwareRate)
        currentTransportRateHz = transportRate
        currentNarrowband = VoiceAudioRatePolicy.isNarrowband(rate: transportRate)
        openStreamingFiles(
            id: RecordingMeta.id(forTimestampMs: timestampMs), sentRate: transportRate, rawRate: hardwareRate)
        wireCaptureCallbacks()

        do {
            try capture.start(targetSampleRate: transportRate)
            isCapturing = true
            beginCaptureWatchdog()
        } catch {
            setupFailure = .audioSessionFailed
            capture.stop()
            await persistRecording()
        }
    }

    // MARK: - Live transcript

    /// The one place a finished take's local state is torn down, called from `persistRecording()`
    /// because that is the single funnel every ending goes through — the user's tap, a lost
    /// connection, an interruption nothing could resume. **Writes nothing into the draft.**
    ///
    /// Unlike the ElevenLabs-era pipeline, this app never composes the dictated text itself: the
    /// backend's `DraftRegionSink` writes every committed word straight into the session's draft
    /// region as it is transcribed (`docs/VOICE_PROTOCOL.md`), server-side, over a plain
    /// repository call rather than back down this socket — a live take's own text was already in
    /// the draft, on every device, before this ever runs. What is left here is releasing the
    /// recorder's claim on `activeDraftKey`, and folding the take's own ack watermark into the
    /// ledger one last time so `mayBeDeleted`/backfill scheduling read the take's true final
    /// state rather than whatever the periodic ledger loop's last tick happened to catch.
    private func finishLiveText() {
        chunkConsumerTask?.cancel()
        chunkConsumerTask = nil
        chunkContinuation?.finish()
        chunkContinuation = nil
        ledgerTask?.cancel()
        ledgerTask = nil
        if let takeId = currentTakeId, let base = activeLedger, base.takeId == takeId {
            var folded = Self.foldAckedRange(
                into: base, ackedUpTo: voiceSession.ackedUpTo, capturedUpTo: voiceSession.capturedUpTo)
            // Nothing left uncovered the moment the take ends — everything captured has already
            // reached the backend, so it really has been delivered.
            if folded.gaps.isEmpty { folded = Self.markingDelivered(folded) }
            activeLedger = folded
            try? LedgerFile.write(folded, to: audioStorage.ledgerURL(id: takeId))
        }
        activeDraftKey = nil
        preVoiceText = ""
    }

    /// Gives up the take without touching the draft — for the failures that happen before any
    /// audio was captured, where the field should read exactly as it did before the tap.
    private func releaseTakeWithoutText() {
        activeDraftKey = nil
        preVoiceText = ""
    }

    /// Turns the uplink's own ack watermark into what the ledger's gap-derivation already
    /// understands: a single `.live` `Segment` covering everything acked so far, empty-text on
    /// purpose. The ledger's job under this protocol is audio-delivery bookkeeping — what has
    /// reached the backend, what has not, and therefore what still needs a backfill or may never
    /// be evicted — never rendering transcript text, which the backend's own draft region already
    /// owns. Passing the whole `0..<ackedUpTo` range every call rather than only the newly-acked
    /// slice is deliberate: `SeamMerge.merge` coalesces it with whatever `.live` coverage the
    /// ledger already had, so a fold can never regress even if a call is skipped or reordered.
    private static func foldAckedRange(into ledger: TranscriptLedger, ackedUpTo: Int, capturedUpTo: Int)
        -> TranscriptLedger
    {
        let liveSegments: [Segment] = ackedUpTo > 0 ? [Segment(range: 0..<ackedUpTo, text: "", source: .live)] : []
        return ledger.folding(
            liveSegments: liveSegments, capturedUpTo: capturedUpTo,
            newlyAcknowledged: ackedUpTo > 0 ? [0..<ackedUpTo] : []
        )
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

    // MARK: - Durable pipeline: ledger and backfill

    private var currentTakeId: String? {
        takeTimestampMs.map { RecordingMeta.id(forTimestampMs: $0) }
    }

    /// The active take's own ledger, kept in memory; a take that is not the one currently running
    /// is read straight off disk — the same split `readLedger`'s every caller relies on.
    private func readLedger(takeId: String) -> TranscriptLedger? {
        takeId == currentTakeId ? activeLedger : LedgerFile.read(from: audioStorage.ledgerURL(id: takeId))
    }

    /// Watches the live session's own ack watermark and writes the ledger whenever it advances —
    /// polling rather than reacting to `@Observable` directly, matching every other loop that
    /// watches this same session from outside a SwiftUI view body. One second is coarse on
    /// purpose: `capturedUpTo`/`ackedUpTo` are advisory (the WAV header is the authoritative
    /// record of what was captured; the backend's own `ack` is the authority on what it received),
    /// so nothing here needs sub-second freshness, only to notice a new gap soon enough to start
    /// backfilling it.
    private func runLedgerLoop(takeId: String) async {
        var lastAckedUpTo = 0
        while !Task.isCancelled, voiceSession.state != .idle {
            if voiceSession.ackedUpTo != lastAckedUpTo {
                lastAckedUpTo = voiceSession.ackedUpTo
                persistLedger(
                    takeId: takeId, ackedUpTo: voiceSession.ackedUpTo, capturedUpTo: voiceSession.capturedUpTo)
            }
            try? await Task.sleep(for: .seconds(1))
        }
        // One last write regardless of how the loop above ended — the final ack or the final
        // `capturedUpTo` can land in the gap between the loop's last tick and the state actually
        // flipping to `.idle`. `finishLiveText()`'s own synchronous fold, called once `stop()`
        // has fully returned, is what actually catches the take's very last moment — this last
        // tick only narrows the window a concurrent backfill pass could read a stale ledger
        // through, it is not itself what makes the final stretch land.
        persistLedger(takeId: takeId, ackedUpTo: voiceSession.ackedUpTo, capturedUpTo: voiceSession.capturedUpTo)
    }

    /// Folds the uplink's own ack watermark into `takeId`'s ledger (`foldAckedRange` — the same
    /// fold `finishLiveText()`'s final synchronous call uses, so neither can disagree about what a
    /// take's last moment holds), and writes the result — the write order the design calls for
    /// (audio already on disk by the time this runs; the ledger is therefore never ahead of it). A
    /// new gap appearing since the last write schedules a backfill loop for it and sounds the
    /// "still catching up" cue.
    private func persistLedger(takeId: String, ackedUpTo: Int, capturedUpTo: Int) {
        guard let base = activeLedger, base.takeId == takeId else { return }
        let previousGapCount = base.gaps.count
        let final = Self.foldAckedRange(into: base, ackedUpTo: ackedUpTo, capturedUpTo: capturedUpTo)
        activeLedger = final
        try? LedgerFile.write(final, to: audioStorage.ledgerURL(id: takeId))
        if !final.gaps.isEmpty {
            if final.gaps.count > previousGapCount {
                feedbackNotifier.handle(.gapOpened)
            }
            scheduleBackfillIfNeeded(takeId: takeId)
        }
    }

    /// One backfill loop per take still owed a gap. A second call for a take already being
    /// worked is a no-op — `runBackfillLoop` re-reads the ledger on every pass, so there is never
    /// a reason for two loops on the same take to exist at once.
    private func scheduleBackfillIfNeeded(takeId: String) {
        guard backfillTasks[takeId] == nil else { return }
        backfillTasks[takeId] = Task { [weak self] in
            await self?.runBackfillLoop(takeId: takeId)
            self?.backfillTasks[takeId] = nil
        }
    }

    /// Runs until every gap this take has is resolved or demoted, reading the ledger fresh each
    /// pass — which is what lets the very same loop serve the take still actively recording (read
    /// from `activeLedger`) and a take `reconcileTakes()` found incomplete at launch (read from
    /// disk) with no separate code path for either.
    ///
    /// 🚨 Gated on `backfillGate(now:)`, never `state` — `state` answers "is a live socket open
    /// and trustworthy right now", which stays `.offline`/`.connecting` with no take recording at
    /// all, so healing an ended take, launch recovery and "Transcribe now" used to wait forever
    /// with nothing that could ever wake them. `backfillGate` only needs the network path itself
    /// satisfied with no recent failure — knowable with no socket open — and reads fresh off
    /// `Date()` on every poll, so this loop's own three-second tick is already the "timer" that
    /// lets its 30-second recent-failure window elapse; nothing else needs to tick it.
    private func runBackfillLoop(takeId: String) async {
        while !Task.isCancelled {
            guard let ledger = readLedger(takeId: takeId), !ledger.gaps.isEmpty else { return }
            let health = connectionHealthBox.value.backfillGate(now: Date())
            guard health == .stable else {
                try? await Task.sleep(for: .seconds(Self.backfillPollSeconds))
                continue
            }
            let requests = BackfillPlanner.plan(
                gaps: ledger.gaps, sampleRate: ledger.sampleRate, capturedUpTo: ledger.capturedUpTo, health: health)
            guard !requests.isEmpty else {
                try? await Task.sleep(for: .seconds(Self.backfillPollSeconds))
                continue
            }

            var newSegments: [Segment] = []
            var resolved: [SampleRange] = []
            var failed: [(range: SampleRange, error: String)] = []
            let language = Self.voiceSettings(from: settingsStore).sttLanguage
            let sampleRate = ledger.sampleRate
            for request in requests {
                guard connectionHealthBox.value.backfillGate(now: Date()) == .stable else { break }
                let outcome = await BatchBackfiller.run(
                    request, sampleRate: sampleRate, language: language, audioReader: audioStorage, takeId: takeId,
                    transcribe: { [weak self] wav, requestLanguage in
                        guard let self else { throw VoiceSocketTransportError.notConnected }
                        return try await self.batchTranscribe(wav: wav, language: requestLanguage)
                    }
                )
                switch outcome {
                case let .segment(segment):
                    newSegments.append(segment)
                    resolved.append(contentsOf: request.gapRanges)
                case .noSpeechDetected:
                    resolved.append(contentsOf: request.gapRanges)
                case let .failed(error):
                    failed.append(contentsOf: request.gapRanges.map { (range: $0, error: error) })
                }
            }
            await applyBackfillOutcome(takeId: takeId, newSegments: newSegments, resolved: resolved, failed: failed)
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// One client-minted take id per source take, for the region a backfill's own recovered text
    /// lands in — stable across every pass so a second pass rewrites the same region rather than
    /// minting a new one (`write_draft_region`'s own `seq` guard needs a consistent identity to
    /// guard). Never the SAME id the live socket's own `DraftRegionSink` used server-side: this
    /// app is never told that one (`docs/VOICE_PROTOCOL.md`'s framing section carries no take id
    /// at all on the live socket), so a long-outage recovery lands as its own region, in whatever
    /// position among the draft's regions it happens to be written — after, not necessarily
    /// exactly where, the words it recovers were actually spoken. A real but accepted limitation;
    /// see this run's own report.
    private var backfillRegionIds: [String: String] = [:]
    private var backfillRegionSeq: [String: Int] = [:]

    /// Applies one backfill pass against the ledger's *current* state
    /// (`TranscriptLedger.applyingBackfill` — never the snapshot `runBackfillLoop` started
    /// reading from, which its own network round trips can leave stale), updates the take's
    /// `RecordingMeta` coverage, and — once every gap this take had is closed — writes whatever
    /// text this pass recovered into the take's own backfill region.
    ///
    /// A take still actively recording never reaches the write below: the live socket is already
    /// delivering everything it can, and a batch pass only ever fires for a gap the live path
    /// missed (a drop longer than the bus's own reconnect grace window) — see
    /// `VoiceUplinkSession`'s own doc comment. `newSegments` carries only what THIS pass
    /// recovered; the region write below sends every `.batch` segment the ledger has accumulated
    /// so far, matching `DraftRegionSink`'s own "always the take's full text so far" contract.
    private func applyBackfillOutcome(
        takeId: String, newSegments: [Segment], resolved: [SampleRange], failed: [(range: SampleRange, error: String)]
    ) async {
        guard let ledger = readLedger(takeId: takeId) else { return }
        var final = ledger.applyingBackfill(newSegments: newSegments, resolved: resolved, failed: failed)

        if takeId == currentTakeId {
            activeLedger = final
        } else if final.mode == .microphone, !newSegments.isEmpty, let draftKey = final.draftKey {
            let recoveredText = final.segments.filter { $0.source == .batch }
                .sorted { $0.range.lowerBound < $1.range.lowerBound }
                .map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
            if !recoveredText.isEmpty {
                let regionId =
                    backfillRegionIds[takeId]
                    ?? {
                        let fresh = "backfill-\(takeId)"
                        backfillRegionIds[takeId] = fresh
                        return fresh
                    }()
                let seq = (backfillRegionSeq[takeId] ?? 0) + 1
                backfillRegionSeq[takeId] = seq
                let prefixedText = "\(VoiceRecordingResult.sttPrefix)\(recoveredText)"
                if let result = try? await apiClient.putDraftRegion(
                    key: draftKey, takeId: regionId, text: prefixedText,
                    state: final.gaps.isEmpty ? "final" : "open", seq: seq
                ), case .written = result {
                    if final.gaps.isEmpty { final = Self.markingDelivered(final) }
                }
            }
        }
        try? LedgerFile.write(final, to: audioStorage.ledgerURL(id: takeId))
        updateRecordingMeta(takeId: takeId, ledger: final)

        if final.gaps.isEmpty {
            if !newSegments.isEmpty { feedbackNotifier.handle(.backfillCompleted) }
        } else if final.gaps.contains(where: \.demoted) {
            feedbackNotifier.handle(.backfillFailed)
        }
    }

    /// `delivered` means the assembled text actually reached its destination — set here, the one
    /// place that is actually true, rather than inferred from `gaps.isEmpty` alone (closing every
    /// gap says nothing about whether the healed text ever made it into a draft anyone will read).
    private static func markingDelivered(_ ledger: TranscriptLedger) -> TranscriptLedger {
        TranscriptLedger(
            takeId: ledger.takeId, mode: ledger.mode, sampleRate: ledger.sampleRate, draftKey: ledger.draftKey,
            preText: ledger.preText, segments: ledger.segments, capturedUpTo: ledger.capturedUpTo, gaps: ledger.gaps,
            boundaries: ledger.boundaries, collecting: ledger.collecting, events: ledger.events, delivered: true,
            acknowledged: ledger.acknowledged
        )
    }

    /// The one caller of the backend's own batch transcription route — it holds the ElevenLabs
    /// key server-side and returns plain text only, no word-level timestamps (unlike the
    /// ElevenLabs-era direct call this replaces). `BatchBackfiller`/`SeamMerge` already have a
    /// no-timestamps fallback (a text suffix/prefix trim capped at eight words) for exactly this
    /// case, so an empty `words` array here degrades gracefully rather than needing its own path.
    private func batchTranscribe(
        wav: Data, language: VoiceSettings.Language
    ) async throws -> (text: String, words: [Word]) {
        let text = try await apiClient.transcribeVoiceTake(
            takeId: UUID().uuidString, wav: wav, languageCode: language == .auto ? nil : language.rawValue)
        return (text: text, words: [])
    }

    /// A take's `RecordingMeta.transcription` after a ledger change — what the recordings screen
    /// reads to show coverage without opening the ledger itself. A no-op for a take
    /// `SettingsStore` never saved (still mid-take, or evicted since).
    private func updateRecordingMeta(takeId: String, ledger: TranscriptLedger) {
        guard let existing = settingsStore.recordings.first(where: { $0.id == takeId }) else { return }
        // `ledger.segments` is already the output of a `SeamMerge.merge` pass — both write paths
        // that ever produce it (`folding`, `applyingBackfill`) run it once; re-running it here
        // would be redundant at best, and — as `VoiceTextAssembly.assembledText`'s own comment
        // explains — a second pass can see ranges the first pass's own trimming already widened,
        // which can mask a real self-trim regression rather than surface it.
        let transcript = ledger.segments.sorted { $0.range.lowerBound < $1.range.lowerBound }.map(\.text).joined(
            separator: " ")
        let updated = RecordingMeta(
            timestampMs: existing.timestampMs, durationMs: existing.durationMs, sampleRate: existing.sampleRate,
            rawSampleRate: existing.rawSampleRate, mic: existing.mic, rawStored: existing.rawStored,
            endedBy: existing.endedBy, silence: existing.silence, stt: existing.stt,
            transcript: transcript.isEmpty ? existing.transcript : transcript, levels: existing.levels,
            narrowband: existing.narrowband, startup: existing.startup, mutedMs: existing.mutedMs,
            transcription: Self.transcriptionMeta(for: ledger)
        )
        settingsStore.updateRecording(updated)
    }

    private static func transcriptionMeta(for ledger: TranscriptLedger) -> TranscriptionMeta {
        let coveredSamples = ledger.coveredRanges.reduce(0) { $0 + $1.count }
        let gapSamples = ledger.gaps.reduce(0) { $0 + $1.range.count }
        let sampleRate = max(1, ledger.sampleRate)
        let coveredMs = Double(coveredSamples) / Double(sampleRate) * 1000
        let gapMs = Double(gapSamples) / Double(sampleRate) * 1000
        let state: TranscriptionMeta.Coverage =
            ledger.gaps.isEmpty ? .complete : (ledger.gaps.allSatisfy(\.demoted) ? .failed : .pending)
        return TranscriptionMeta(
            coveredMs: coveredMs, gapMs: gapMs, gapCount: ledger.gaps.count, state: state, delivered: ledger.delivered)
    }

    // MARK: - Connection health

    /// `self` is a valid capture target only once every stored property has a value — called last
    /// in `init`, after every property (including `voiceSession`) is assigned.
    private func wireNetworkPathObserver() {
        pathObserver.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                Self.applyConnectionHealthEvent(event, box: self.connectionHealthBox, notifier: self.feedbackNotifier)
                // "On path satisfied, attempt immediately" — skips whatever backoff a reconnect
                // is still waiting out, per the design's own reconnection rule.
                if case .pathSatisfied(true) = event, self.voiceSession.state == .reconnecting {
                    self.voiceSession.retryReconnectNow()
                }
            }
        }
        pathObserver.start()
    }

    /// Feeds one event into the health machine and sounds "reconnected" exactly once — the instant
    /// `ConnectionHealth` reaches `.stable` from anything else, never on every bare socket
    /// reconnect. `FeedbackPolicy` trusts this event to mean the link is genuinely back, not
    /// merely open again; this is the one place that contract is actually kept.
    private static func applyConnectionHealthEvent(
        _ event: ConnectionHealthEvent, box: ConnectionHealthBox, notifier: VoiceFeedbackNotifier
    ) {
        let previous = box.value.state
        let next = box.value.handle(event, now: Date())
        if previous != next {
            AppVoiceDiagnosticsLog.shared.log(
                .info, .connectionHealth, "\(previous.rawValue) -> \(next.rawValue) (\(event))")
        }
        if previous != .stable, next == .stable {
            notifier.handle(.reconnected)
        }
    }

    func toggleMute() {
        voiceSession.toggleMute()
    }

    /// Re-transcribes a whole past recording through the same backend route the durable
    /// pipeline's own backfill uses — no token to mint, the backend holds the ElevenLabs key.
    func transcribe(wav: Data, language: VoiceSettings.Language) async throws -> String {
        try await batchTranscribe(wav: wav, language: language).text
    }

    /// The recordings screen's "Transcribe now" — makes sure a take with open gaps has a backfill
    /// loop running for it, the exact same loop `persistLedger`/`reconcileTakes` schedule on their
    /// own. A no-op for a take with no gaps at all, or one already being worked.
    func transcribeRemainingGaps(id: String) {
        guard let ledger = readLedger(takeId: id), !ledger.gaps.isEmpty else { return }
        scheduleBackfillIfNeeded(takeId: id)
    }

    /// Deletes a past recording by Freddy's own tap — distinct from the retention cap's automatic
    /// eviction, though both end at `onRecordingEvicted`, which is what actually removes the
    /// bytes.
    func deleteRecording(_ meta: RecordingMeta) {
        settingsStore.removeRecording(id: meta.id)
    }

    /// Stops the take and persists the recording (audio + metadata). Nothing to return any more —
    /// the backend already wrote every committed word into the draft's own region as the take
    /// ran; a caller has nothing left to insert.
    func stop() async {
        guard isCapturing || voiceSession.state != .idle else { return }
        let wasOffline = isRecordingOffline
        capture.stop()
        isCapturing = false
        endCaptureWatchdog()
        // A no-op when `wasOffline` — the uplink was never started for this take, and `stop()`
        // itself guards `state != .idle`.
        await voiceSession.stop(reason: .user)
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)

        await persistRecording()
        AppVoiceDiagnosticsLog.shared.log(.info, .mode, wasOffline ? "offline take stopped" : "microphone take stopped")
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
    ///
    /// Activated exclusive first, then re-set mixable — see `activateExclusiveThenMixable`'s own
    /// doc comment for why, in both modes.
    ///
    /// `.defaultToSpeaker` is what keeps an earcon audible with no headset connected:
    /// `.playAndRecord` alone routes output to the receiver, which nobody hears with the phone in
    /// a pocket — exactly the case a connection-health cue exists to reach.
    ///
    func configureAudioSession() throws {
        try activateExclusiveThenMixable(mode: .measurement)
    }

    /// Activating the session exclusive (no `.mixWithOthers`) first is what pauses whatever else
    /// was already playing — Freddy's own expectation when a take or a call starts, the same
    /// effect this used to reach with `.duckOthers` before it was dropped. Re-setting the category
    /// with `.mixWithOthers` immediately after, without ever deactivating in between, is what
    /// keeps anything that starts playing LATER (Spotify resumed from an AirPods gesture, a video,
    /// a voice note) from interrupting this session in turn: once mixable, the system no longer
    /// treats a second, non-mixable session's own activation as a conflict with ours. Without this
    /// second step, ANY other app's non-mixable audio starting mid-take or mid-call sends this
    /// session an interruption it never asked for.
    private func activateExclusiveThenMixable(mode: AVAudioSession.Mode) throws {
        let options: AVAudioSession.CategoryOptions = [
            .allowBluetooth, .overrideMutedMicrophoneInterruption, .defaultToSpeaker,
        ]
        try audioSession.setCategory(.playAndRecord, mode: mode, options: options)
        try audioSession.setActive(true)
        try audioSession.setCategory(.playAndRecord, mode: mode, options: options.union(.mixWithOthers))
        applyPreferredMicrophone()
    }

    /// `AVAudioSession.setPreferredInput` — the platform's equivalent of the web's
    /// `deviceId: { exact }` constraint (`web/src/hooks/useVoiceRecording.ts`'s
    /// `audioConstraints`). Called from `configureAudioSession()`, so it runs both on a fresh
    /// start and on every resume after an interruption — a route can change while paused (an
    /// AirPod case reconnecting to a different port, say), and the chosen device should still win
    /// once capture resumes.
    ///
    /// An empty id means whatever the system would route anyway, matching the web's own
    /// `deviceId ? {...} : true`. A stored id that names no currently available port — the
    /// headset went back in its case — is forgotten rather than kept, exactly as
    /// `startRecording`'s catch branch forgets a vanished `micDeviceId` on the web: kept, it
    /// would fail the same way on every future take, and the picker would keep claiming a device
    /// that is not there.
    private func applyPreferredMicrophone() {
        let deviceId = settingsStore.micDeviceId
        guard !deviceId.isEmpty else { return }
        guard let port = audioSession.availableInputs?.first(where: { $0.uid == deviceId }) else {
            forgetStaleMicrophoneChoice()
            return
        }
        do {
            try audioSession.setPreferredInput(port)
        } catch {
            forgetStaleMicrophoneChoice()
        }
    }

    private func forgetStaleMicrophoneChoice() {
        settingsStore.setMicDeviceId("")
        toasts.show("The microphone from settings is gone — recording with the default one.")
    }

    private func refreshAvailableMicrophones() {
        availableMicrophones = (audioSession.availableInputs ?? []).map {
            MicrophoneOption(uid: $0.uid, name: $0.portName)
        }
    }

    private func observeRouteChanges() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: audioSession, queue: .main
        ) { [weak self] notification in
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            AppVoiceDiagnosticsLog.shared.log(.info, .audioSession, "route changed (reason \(reasonValue ?? 0))")
            Task { @MainActor [weak self] in self?.refreshAvailableMicrophones() }
        }
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
            AppVoiceDiagnosticsLog.shared.log(
                .info, .audioSession,
                type == .began ? "interruption began" : "interruption ended (shouldResume: \(shouldResume))")
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
        feedbackNotifier.handle(.interruptionPaused)
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
            try capture.start(targetSampleRate: currentTransportRateHz)
            isCapturing = true
            beginCaptureWatchdog()
            checkRawStreamStillMatchesHardwareRate()
            voiceSession.resumeAfterInterruption()
            feedbackNotifier.handle(.interruptionResumed)
        } catch {
            await giveUpAfterInterruption()
        }
    }

    /// An interruption that could not resume ends the take the same way the capture watchdog's
    /// own give-up does — the microphone is gone and nothing here can get it back, so `captureGaveUp`
    /// is the one cue and notification for "this take is over and it wasn't the usual tap to stop".
    private func giveUpAfterInterruption() async {
        await voiceSession.stop(reason: .interrupted)
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        await persistRecording()
        feedbackNotifier.handle(.captureGaveUp)
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
                self.currentLevel = rms
                self.peakAmplitude = max(self.peakAmplitude, rms)
                self.levelSum += rms
                self.levelCount += 1
            }
        }
        // One ordered consumer for every captured chunk, not one unstructured `Task` per chunk.
        // `VoiceUplinkSession.ingestAudioChunk`'s own contract requires the app await each call
        // from a single consuming task, because that is the only thing that keeps chunks in
        // order: two chunks each spawned as their own `Task` can resume out of order across the
        // transport's own `await`, handing `SessionTimeline` an offset that no longer matches what
        // actually reached the socket. Feeding a stream synchronously from `onChunk` and draining
        // it from one long-running task is what actually gives that guarantee, rather than merely
        // asserting it in a doc comment. A fresh stream per take — the old one's consumer task is
        // cancelled first, so a chunk that arrives right at a restart can never feed the session
        // that is about to start in its place.
        let (chunkStream, continuation) = AsyncStream<[Int16]>.makeStream()
        chunkContinuation = continuation
        chunkConsumerTask?.cancel()
        chunkConsumerTask = Task { [weak self] in
            for await samples in chunkStream {
                await self?.consumeCapturedChunk(samples)
            }
        }
        capture.onChunk = { samples in
            continuation.yield(samples)
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

    /// What `chunkConsumerTask` drains, one at a time, in the order `MicrophoneCapture` delivered
    /// them — the single place a captured buffer becomes both a disk append and a
    /// `voiceSession.ingestAudioChunk` call.
    private func consumeCapturedChunk(_ samples: [Int16]) async {
        lastChunkAt = Date()
        // The offset this chunk lands at in the take — read before the append below, so it names
        // where the chunk about to be written *starts*, matching the sample count
        // `ingestAudioChunk(at:)` needs to keep `SessionTimeline` (and everything addressed off
        // it — segments, gaps, the ledger) aligned with what actually reached disk.
        let offset = streamingSent?.sampleCount ?? 0
        // Mirrors what `VoiceRecordingSession.ingestAudioChunk` actually transmits when muted —
        // the socket receives zeroes, so the saved "sent" recording should too, rather than
        // silently disagreeing with what ElevenLabs was given.
        let effective = voiceSession.isMuted ? [Int16](repeating: 0, count: samples.count) : samples
        streamingSent?.append(pcm16le: effective)
        await voiceSession.ingestAudioChunk(pcm16le: samples, at: offset)
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
            feedbackNotifier.handle(.captureGaveUp)
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
            try capture.start(targetSampleRate: currentTransportRateHz)
            lastChunkAt = Date()
            checkRawStreamStillMatchesHardwareRate()
        } catch {
            // Same ordering rule as `recoverSilentMicrophone`'s give-up branch, and for the same
            // reason: one of this method's callers is the watchdog task itself.
            isCapturing = false
            await voiceSession.stop(reason: .error)
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            await persistRecording()
            feedbackNotifier.handle(.captureGaveUp)
            endCaptureWatchdog()
        }
    }

    // MARK: - Persisting a finished take

    private func persistRecording() async {
        // Before any of the early returns below: a take that produced no audio worth keeping
        // still has to hand its text back (or put the field back the way it was), and every way
        // a take can end arrives here.
        finishLiveText()
        // Captured before the early returns below, and before `activeLedger` is cleared at the
        // end of this method — `nil` for a take that never got far enough to open a ledger, and
        // always `nil` for an offline take, which never opens one at all.
        let takeLedger = activeLedger
        let wasOffline = isRecordingOffline
        let offlineName = pendingOfflineName
        isRecordingOffline = false
        pendingOfflineName = nil

        let sent = streamingSent
        let raw = streamingRaw
        streamingSent = nil
        streamingRaw = nil
        sent?.finalize()
        raw?.finalize()
        // An offline take never starts `voiceSession`, so its own `result` stays at rest the
        // whole time (`durationMs` reads 0 forever) — the captured samples are this take's only
        // record of how long it ran.
        let offlineDurationMs = Int(Double(sent?.sampleCount ?? 0) / Double(currentTransportRateHz) * 1000)
        let result: (endedBy: RecordingEndReason, durationMs: Int, mutedMs: Int) =
            wasOffline ? (endedBy: .user, durationMs: offlineDurationMs, mutedMs: 0) : voiceSession.result

        guard let timestampMs = takeTimestampMs else { return }
        takeTimestampMs = nil
        let id = RecordingMeta.id(forTimestampMs: timestampMs)

        guard result.durationMs > 0, sent?.hasData == true else {
            // Nothing worth keeping — `start()` already opened files for this id, so clean up the
            // stubs rather than leaving 44-byte orphans behind.
            await audioStorage.delete(id: id)
            activeLedger = nil
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
            sampleRate: Double(currentTransportRateHz),
            rawSampleRate: rawKept ? streamingRawSampleRate.map(Double.init) : nil,
            mic: mic,
            rawStored: rawKept,
            endedBy: result.endedBy,
            // Nothing gates on this any more — the new protocol streams continuously while the
            // gate is open, and the setting this used to read no longer exists.
            silence: nil,
            stt: SttMeta(
                model: "scribe_v2_realtime", language: settings.sttLanguage.rawValue,
                vadSilenceSecs: 1.5, vadThreshold: 0.4
            ),
            // Only what a backfill recovered — an ordinary take with no gap has nothing here any
            // more, since the backend writes its text straight into the draft and never back to
            // this device. A real, accepted narrowing relative to the ElevenLabs-era pipeline;
            // see this run's own report.
            transcript: takeLedger.map { VoiceTextAssembly.assembledText(from: $0) }.flatMap { $0.isEmpty ? nil : $0 },
            levels: LevelStats(
                peak: peakAmplitude, rms: averageLevel, clippedSamples: 0, totalSamples: sent?.sampleCount ?? 0
            ),
            narrowband: currentNarrowband,
            startup: nil,
            mutedMs: result.mutedMs > 0 ? Double(result.mutedMs) : nil,
            transcription: takeLedger.map(Self.transcriptionMeta(for:)),
            name: offlineName,
            mode: wasOffline ? .offline : nil
        )
        settingsStore.saveRecording(meta)
        // A take reconnecting endlessly, or whose transcription stopped for a fatal reason, was
        // already told about it at the moment it happened — through `feedbackNotifier`, at the
        // drop and at the fatal-error site inside `VoiceRecordingSession` itself. Nothing here
        // ends a take for a connection reason any more, so there is no separate "it ended badly"
        // notice left to send at this point.
        activeLedger = nil
    }

    private func currentInputLabel() -> String {
        audioSession.currentRoute.inputs.first?.portName ?? "Microphone"
    }

    // MARK: - Startup reconciliation

    /// A take that survives a hard kill — force-quit, an OS kill under memory pressure, a dead
    /// battery — never reaches `persistRecording()`, so its WAV file is complete and playable on
    /// disk while `settingsStore.recordings` has no entry for it, and the plus-icon picker shows
    /// nothing. This walks the Recordings directory for exactly that gap and synthesizes a
    /// `.crashed`-tagged entry for anything it finds — see `RecordingReconciliation`'s own doc
    /// comment for why this exists at all.
    ///
    /// 🚨 Never deletes anything. An id whose header cannot be read, or whose header declares no
    /// audio (a `start()` stub the process died before ever appending to), is left on disk
    /// exactly as found rather than cleaned up — the one thing this must not become is the
    /// startup cleanup that destroys the take it was built to save.
    ///
    /// Call once, at launch, before any screen has a chance to render an empty picker for a take
    /// that is actually sitting right there — `AppEnvironment.loadStartupState()`.
    ///
    /// Two passes: first every take with audio on disk but no `RecordingMeta` becomes a
    /// `.crashed` row (exactly as `reconcileOrphanedRecordings` always did), then every take that
    /// is either one of those orphans or already carries a ledger file has that ledger reconciled
    /// against what the header says was actually captured, and a backfill loop scheduled for
    /// whatever gap that leaves open. A take `settingsStore` already knew about with no ledger at
    /// all — a recording from before this pipeline existed — is left untouched: synthesizing one
    /// for it would treat its whole, already-transcribed length as a single unrecovered gap and
    /// send it to the batch endpoint for nothing.
    func reconcileTakes() {
        let known = Set(settingsStore.recordings.map(\.id))
        let allIds = audioStorage.idsOnDisk()
        let orphanIds = RecordingReconciliation.orphanedIds(onDisk: allIds, known: known)

        for id in orphanIds.sorted() {
            guard let header = audioStorage.sentHeader(id: id) else { continue }
            let take = RecordingReconciliation.OrphanedTake(
                id: id, sampleRate: header.sampleRate, dataSize: header.dataSize,
                rawStored: audioStorage.hasRaw(id: id))
            guard let meta = RecordingReconciliation.metadata(for: take) else { continue }
            settingsStore.saveRecording(meta)
        }

        for id in allIds.sorted() where orphanIds.contains(id) || audioStorage.hasLedger(id: id) {
            reconcileLedger(id: id)
        }
    }

    /// One take's ledger against what its header's clamped sample count says was actually
    /// captured — the durable-pipeline half of the launch pass. A kill mid-take leaves audio the
    /// ledger's last write does not cover; this is what turns that into a gap a backfill loop can
    /// close, the same rule `TranscriptLedger.derivedGaps` applies while a take is still live.
    private func reconcileLedger(id: String) {
        guard let capturedUpTo = audioStorage.clampedCapturedSampleCount(id: id), capturedUpTo > 0,
            let sampleRate = audioStorage.sentHeader(id: id)?.sampleRate, sampleRate > 0
        else { return }
        let existing = LedgerFile.read(from: audioStorage.ledgerURL(id: id))
        let reconciled = RecordingReconciliation.reconcile(
            ledger: existing, takeId: id, sampleRate: sampleRate, capturedSampleCount: capturedUpTo)
        guard !reconciled.gaps.isEmpty else { return }
        try? LedgerFile.write(reconciled, to: audioStorage.ledgerURL(id: id))
        updateRecordingMeta(takeId: id, ledger: reconciled)
        scheduleBackfillIfNeeded(takeId: id)
    }

    // MARK: - Settings mapping

    /// `SettingsStore` persists `SttLanguage` (this app's own enum, deliberately with no
    /// provider-fallback case); `VoiceRecordingSession` speaks `VoiceSettings.Language` (the
    /// package's port of the same three web values). Same three cases, two independent enums —
    /// this is the one place that needs to know that. Internal rather than `private`: call mode's
    /// own per-cycle `VoiceRecordingSession`s need the identical mapping and reuse this directly
    /// rather than carrying a second copy of the same three-way switch.
    static func voiceSettings(from settingsStore: SettingsStore) -> VoiceSettings {
        let language: VoiceSettings.Language =
            switch settingsStore.sttLanguage {
            case .auto: .auto
            case .en: .en
            case .de: .de
            }
        return VoiceSettings(sttLanguage: language, micDeviceId: settingsStore.micDeviceId)
    }
}
