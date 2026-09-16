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

    private(set) var voiceSession: VoiceRecordingSession
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
    /// Same discipline as `interruptionObserver`, for `AVAudioSession.routeChangeNotification`.
    private nonisolated(unsafe) var routeChangeObserver: NSObjectProtocol?

    init(apiClient: PaiApiClient, settingsStore: SettingsStore, drafts: DraftStore, toasts: ToastCenter) {
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
        let audioStorage = self.audioStorage

        voiceSession = VoiceRecordingSession(
            dependencies: VoiceRecordingDependencies(
                mintToken: { purpose in try await apiClient.mintVoiceToken(purpose: purpose) },
                makeRealtimeTransport: { URLSessionVoiceRealtimeTransport() },
                // The session is `@MainActor`, so it only ever calls this from the main actor —
                // but the dependency's type cannot say so. Asserting the isolation we already have
                // beats making the settings read `nonisolated`, which it genuinely is not.
                settings: { MainActor.assumeIsolated { Self.voiceSettings(from: settingsStore) } },
                ledgerStorage: audioStorage,
                audioReader: audioStorage,
                feedback: { event in MainActor.assumeIsolated { feedbackNotifier.handle(event) } },
                health: { MainActor.assumeIsolated { connectionHealthBox.value.state } },
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
        feedbackNotifier.beginTake(id: RecordingMeta.id(forTimestampMs: timestampMs))
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
            let takeId = RecordingMeta.id(forTimestampMs: timestampMs)
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
        ledgerTask?.cancel()
        ledgerTask = nil
        defer {
            activeDraftKey = nil
            preVoiceText = ""
        }
        // A caller driving its own composer text passes no key; there is nothing to write, but
        // the claim on the recorder still has to be released, which is what the `defer` is for.
        guard let draftKey = activeDraftKey else { return }
        let prefixed = assembledPrefixedText()
        let combined =
            prefixed.isEmpty
            ? preVoiceText
            : (preVoiceText.isEmpty ? prefixed : "\(preVoiceText) \(prefixed)")
        drafts.setDraftText(key: draftKey, text: combined)
    }

    /// The take's prefixed text as of right now — from the ledger when one exists (live segments
    /// plus whatever backfill has healed so far, with a marker over any gap still open), falling
    /// back to the session's own `result.prefixedText` for a take that never got far enough to
    /// open a ledger (a start failure before the first sample, say).
    private func assembledPrefixedText() -> String {
        guard let ledger = activeLedger else { return voiceSession.result.prefixedText }
        let text = Self.assembledText(from: ledger, capturedUpTo: voiceSession.capturedUpTo)
        guard !text.isEmpty else { return "" }
        return "\(VoiceRecordingResult.sttPrefix)\(text)"
    }

    /// A ledger's segments in take order, joined by a space, with an inline `…` marker where a
    /// gap is still open (decision D2) — computed once here rather than duplicated between the
    /// take-ending path above and the recovered-take healing path below.
    private static func assembledText(from ledger: TranscriptLedger, capturedUpTo: Int) -> String {
        let merged = SeamMerge.merge(ledger.segments)
        let gaps = ledger.derivedGaps(capturedUpTo: capturedUpTo)
        let parts: [(offset: Int, text: String)] =
            merged.map { ($0.range.lowerBound, $0.text) } + gaps.map { ($0.range.lowerBound, "…") }
        return parts.sorted { $0.offset < $1.offset }.map(\.text).joined(separator: " ")
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

    // MARK: - Durable pipeline: ledger and backfill

    private var currentTakeId: String? { takeTimestampMs.map { RecordingMeta.id(forTimestampMs: $0) } }

    /// The active take's own ledger, kept in memory; a take that is not the one currently running
    /// is read straight off disk — the same split `readLedger`'s every caller relies on.
    private func readLedger(takeId: String) -> TranscriptLedger? {
        takeId == currentTakeId ? activeLedger : LedgerFile.read(from: audioStorage.ledgerURL(id: takeId))
    }

    /// Watches the live session for a new committed segment or a state change and writes the
    /// ledger when either happens — polling rather than reacting to `@Observable` directly,
    /// matching every other loop that watches this same session from outside a SwiftUI view body.
    /// One second is coarse on purpose: `capturedUpTo` is advisory (the WAV header is the
    /// authoritative record, per the design), so nothing here needs sub-second freshness, only to
    /// notice a new segment — and a gap it might have opened — soon enough to start backfilling it.
    private func runLedgerLoop(takeId: String) async {
        var lastSegmentCount = 0
        while !Task.isCancelled, voiceSession.state != .idle {
            if voiceSession.committedSegments.count != lastSegmentCount {
                lastSegmentCount = voiceSession.committedSegments.count
                persistLedger(takeId: takeId)
            }
            try? await Task.sleep(for: .seconds(1))
        }
        // One last write regardless of how the loop above ended — the final segment or the
        // final `capturedUpTo` can land in the gap between the loop's last tick and the state
        // actually flipping to `.idle`.
        persistLedger(takeId: takeId)
    }

    /// Folds the session's own `committedSegments`/`capturedUpTo` into the ledger, merges in
    /// whatever backfill has already recovered for this take, and writes the result — the write
    /// order the design calls for (audio already on disk by the time this runs; the ledger is
    /// therefore never ahead of it). A new gap appearing since the last write schedules a backfill
    /// loop for it and sounds the "still catching up" cue.
    private func persistLedger(takeId: String) {
        guard let base = activeLedger else { return }
        let recoveredSegments = base.segments.filter { $0.source == .batch || $0.source == .recovery }
        let merged = SeamMerge.merge(voiceSession.committedSegments + recoveredSegments)
        let capturedUpTo = voiceSession.capturedUpTo
        let candidate = TranscriptLedger(
            takeId: base.takeId, mode: base.mode, sampleRate: base.sampleRate, draftKey: base.draftKey,
            preText: base.preText, segments: merged, capturedUpTo: capturedUpTo, gaps: base.gaps,
            boundaries: base.boundaries, collecting: base.collecting, events: base.events, delivered: base.delivered
        )
        let newGaps = candidate.derivedGaps(capturedUpTo: capturedUpTo)
        let previousGapCount = base.gaps.count
        let final = TranscriptLedger(
            takeId: candidate.takeId, mode: candidate.mode, sampleRate: candidate.sampleRate,
            draftKey: candidate.draftKey, preText: candidate.preText, segments: merged, capturedUpTo: capturedUpTo,
            gaps: newGaps, boundaries: candidate.boundaries, collecting: candidate.collecting,
            events: candidate.events, delivered: candidate.delivered
        )
        activeLedger = final
        try? LedgerFile.write(final, to: audioStorage.ledgerURL(id: takeId))
        if !newGaps.isEmpty {
            if newGaps.count > previousGapCount {
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
    /// disk) with no separate code path for either. Nothing is spent while the link is anything
    /// but `.stable` (`BackfillPlanner.plan`'s own gate); this loop's job above that is only to
    /// keep checking.
    private func runBackfillLoop(takeId: String) async {
        while !Task.isCancelled {
            guard let ledger = readLedger(takeId: takeId), !ledger.gaps.isEmpty else { return }
            guard connectionHealthBox.value.state == .stable else {
                try? await Task.sleep(for: .seconds(Self.backfillPollSeconds))
                continue
            }
            let requests = BackfillPlanner.plan(
                gaps: ledger.gaps, sampleRate: ledger.sampleRate, capturedUpTo: ledger.capturedUpTo,
                health: connectionHealthBox.value.state)
            guard !requests.isEmpty else {
                try? await Task.sleep(for: .seconds(Self.backfillPollSeconds))
                continue
            }

            var updatedGaps = ledger.gaps
            var newSegments: [Segment] = []
            let language = Self.voiceSettings(from: settingsStore).sttLanguage
            let sampleRate = ledger.sampleRate
            for request in requests {
                guard connectionHealthBox.value.state == .stable else { break }
                let outcome = await BatchBackfiller.run(
                    request, sampleRate: sampleRate, language: language, audioReader: audioStorage, takeId: takeId,
                    transcribe: { [weak self] wav, requestLanguage in
                        guard let self else { throw VoiceTransportError.notConnected }
                        return try await self.batchTranscribe(
                            wav: wav, language: requestLanguage, sampleRate: sampleRate)
                    }
                )
                switch outcome {
                case let .segment(segment):
                    newSegments.append(segment)
                    updatedGaps.removeAll { request.gapRanges.contains($0.range) }
                case .noSpeechDetected:
                    updatedGaps.removeAll { request.gapRanges.contains($0.range) }
                case let .failed(error):
                    for gapRange in request.gapRanges {
                        guard let index = updatedGaps.firstIndex(where: { $0.range == gapRange }) else { continue }
                        updatedGaps[index] = BackfillPlanner.recordFailure(updatedGaps[index], error: error)
                    }
                }
            }
            applyBackfillOutcome(takeId: takeId, newSegments: newSegments, updatedGaps: updatedGaps)
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// Merges what one backfill pass produced into the ledger, updates the take's `RecordingMeta`
    /// coverage, and — once every gap this take had is closed — appends the healed text into its
    /// draft (a take that is still the active one gets this for free through `assembledPrefixedText`
    /// instead, so this only fires for a take that has already ended) and sounds the healed cue.
    private func applyBackfillOutcome(takeId: String, newSegments: [Segment], updatedGaps: [Gap]) {
        guard let ledger = readLedger(takeId: takeId) else { return }
        let merged = SeamMerge.merge(ledger.segments + newSegments)
        let delivered = updatedGaps.isEmpty ? true : ledger.delivered
        let final = TranscriptLedger(
            takeId: ledger.takeId, mode: ledger.mode, sampleRate: ledger.sampleRate, draftKey: ledger.draftKey,
            preText: ledger.preText, segments: merged, capturedUpTo: ledger.capturedUpTo, gaps: updatedGaps,
            boundaries: ledger.boundaries, collecting: ledger.collecting, events: ledger.events, delivered: delivered
        )
        try? LedgerFile.write(final, to: audioStorage.ledgerURL(id: takeId))

        if takeId == currentTakeId {
            activeLedger = final
        } else if final.gaps.isEmpty, !newSegments.isEmpty, let draftKey = final.draftKey {
            appendHealedText(final, draftKey: draftKey)
        }
        updateRecordingMeta(takeId: takeId, ledger: final)

        if final.gaps.isEmpty {
            if !newSegments.isEmpty { feedbackNotifier.handle(.backfillCompleted) }
        } else if final.gaps.contains(where: \.demoted) {
            feedbackNotifier.handle(.backfillFailed)
        }
    }

    /// A take that is no longer the active one — recovered at launch, or simply finished before
    /// its own backfill did — has its healed text appended to the draft it belonged to, prefixed
    /// exactly as a live take's is, since the draft may well have moved on since the take ended.
    /// Called once, the round a take's last gap closes, never per partial pass — appending the
    /// whole assembled text on every pass would duplicate it.
    private func appendHealedText(_ ledger: TranscriptLedger, draftKey: String) {
        let text = Self.assembledText(from: ledger, capturedUpTo: ledger.capturedUpTo)
        guard !text.isEmpty else { return }
        let prefixed = "\(VoiceRecordingResult.sttPrefix)\(text)"
        let current = drafts.draft(for: draftKey).text
        drafts.setDraftText(key: draftKey, text: current.isEmpty ? prefixed : "\(current) \(prefixed)")
    }

    /// The one caller of the batch endpoint's word-timestamp variant — converts its
    /// connection-relative-to-the-request seconds into the take-offset-zero samples
    /// `BatchBackfiller` expects back, the batch counterpart to what `SessionTimeline` does for
    /// the live socket.
    private func batchTranscribe(
        wav: Data, language: VoiceSettings.Language, sampleRate: Int
    ) async throws -> (text: String, words: [Word]) {
        let token = try await apiClient.mintVoiceToken(purpose: .batch).token
        let result = try await VoiceBatchTranscriber().transcribeWithWordTimestamps(
            wav: wav, token: token, language: language)
        switch result {
        case let .words(text, words):
            let converted: [Word] = words.compactMap { word in
                let start = Int((word.start * Double(sampleRate)).rounded())
                let end = Int((word.end * Double(sampleRate)).rounded())
                guard start < end else { return nil }
                return Word(range: start..<end, text: word.text, logprob: word.logprob)
            }
            return (text: text, words: converted)
        case .noSpeechDetected:
            return (text: "", words: [])
        case let .failed(error):
            throw error
        }
    }

    /// A take's `RecordingMeta.transcription` after a ledger change — what the recordings screen
    /// reads to show coverage without opening the ledger itself. A no-op for a take
    /// `SettingsStore` never saved (still mid-take, or evicted since).
    private func updateRecordingMeta(takeId: String, ledger: TranscriptLedger) {
        guard let existing = settingsStore.recordings.first(where: { $0.id == takeId }) else { return }
        let transcript = SeamMerge.merge(ledger.segments)
            .sorted { $0.range.lowerBound < $1.range.lowerBound }.map(\.text).joined(separator: " ")
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
        if previous != .stable, next == .stable {
            notifier.handle(.reconnected)
        }
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
    ///
    /// `.defaultToSpeaker` is what keeps an earcon audible with no headset connected:
    /// `.playAndRecord` alone routes output to the receiver, which nobody hears with the phone in
    /// a pocket — exactly the case a connection-health cue exists to reach.
    private func configureAudioSession() throws {
        try audioSession.setCategory(
            .playAndRecord, mode: .measurement,
            options: [.duckOthers, .allowBluetooth, .overrideMutedMicrophoneInterruption, .defaultToSpeaker])
        try audioSession.setActive(true)
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
        ) { [weak self] _ in
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
            try capture.start(targetSampleRate: voiceSession.transportSampleRateHz)
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
                // The offset this chunk lands at in the take — read before the append below, so
                // it names where the chunk about to be written *starts*, matching the sample
                // count `ingestAudioChunk(at:)` needs to keep `SessionTimeline` (and everything
                // addressed off it — segments, gaps, the ledger) aligned with what actually
                // reached disk.
                let offset = self.streamingSent?.sampleCount ?? 0
                // Mirrors what `VoiceRecordingSession.ingestAudioChunk` actually transmits when
                // muted — the socket receives zeroes, so the saved "sent" recording should too,
                // rather than silently disagreeing with what ElevenLabs was given.
                let effective = self.voiceSession.isMuted ? [Int16](repeating: 0, count: samples.count) : samples
                self.streamingSent?.append(pcm16le: effective)
                await self.voiceSession.ingestAudioChunk(pcm16le: samples, at: offset)
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
        // end of this method — `nil` for a take that never got far enough to open a ledger.
        let takeLedger = activeLedger

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
            sampleRate: Double(result.sampleRate),
            rawSampleRate: rawKept ? streamingRawSampleRate.map(Double.init) : nil,
            mic: mic,
            rawStored: rawKept,
            endedBy: result.endedBy,
            silence: SilenceMeta(
                enabled: settings.silenceDetectionEnabled, threshold: settings.silenceThreshold,
                durationMs: Double(settings.silenceDurationMs), triggered: result.silenceGatedMs > 0,
                gatedMs: Double(result.silenceGatedMs)
            ),
            stt: SttMeta(
                model: VoiceRealtimeProtocol.modelId, language: settings.sttLanguage.rawValue,
                vadSilenceSecs: Double(VoiceRealtimeProtocol.vadSilenceThresholdSecs) ?? 1.5,
                vadThreshold: Double(VoiceRealtimeProtocol.vadThreshold) ?? 0.4
            ),
            transcript: takeLedger.map { Self.assembledText(from: $0, capturedUpTo: $0.capturedUpTo) }
                .flatMap { $0.isEmpty ? nil : $0 } ?? (result.text.isEmpty ? nil : result.text),
            levels: LevelStats(
                peak: peakAmplitude, rms: averageLevel, clippedSamples: 0, totalSamples: sent?.sampleCount ?? 0
            ),
            narrowband: result.narrowband,
            startup: nil,
            mutedMs: result.mutedMs > 0 ? Double(result.mutedMs) : nil,
            transcription: takeLedger.map(Self.transcriptionMeta(for:))
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
