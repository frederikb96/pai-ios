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
/// (`.reconnecting`, a dropped socket) never pauses the durable file underneath it. The recorder half
/// knows of no other module, and this type is what keeps that true by never letting a connection problem reach `capture` or
/// `streamingSent`.
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
/// puts it on the user's other clients at the same time.
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

    /// Finishing from the moment stop is pressed, even through the short tail that keeps the
    /// microphone open after it — the press is what the UI answers to.
    var state: VoiceRecordingState {
        isStopRequested && voiceSession.state != .idle ? .stopping : voiceSession.state
    }
    var isMuted: Bool { voiceSession.isMuted }
    /// The silence gate is holding the microphone back right now.
    var isWithholding: Bool { voiceSession.isWithholding }
    /// Set for the whole of `stop()`, tail included.
    private var isStopRequested = false
    /// Stop waiting asked for during the stop tail, before the uplink itself is finishing: the
    /// gate still closes with the seal, but nothing waits for the receipt.
    private var stopWaitingRequestedDuringTail = false
    /// How long capture keeps running after stop is pressed — the last syllable is usually still
    /// being said when the thumb lands.
    private static let stopTailMs = 300
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
    /// The name of the standalone recording running now (`startStandalone(name:sttMode:)`), or
    /// `nil` — a dictation, or nothing at all. A standalone take has no draft; its result lands on
    /// the recording.
    private(set) var activeStandaloneName: String?
    var isRecordingStandalone: Bool { activeStandaloneName != nil }
    /// What the running take asks of the transcription engine.
    var activeSttMode: VoiceSttMode { voiceSession.sttMode }
    /// Every take this device still owes the server for, or waits on a result from, by take id —
    /// kept in memory beside the ledgers so a composer can ask about its own on every render.
    private(set) var owedTakes: [String: OwedTakeSummary] = [:]
    /// Takes whose words went out with a send. The live text loop writes nothing more into the
    /// draft for them: the composer was just emptied by that send.
    private var heldClientMessageIds: [String: String] = [:]
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
    /// The take's audio exactly as the voice socket carried it — 16 kHz, muted windows zeroed —
    /// written to disk as it arrives rather than held in memory for the whole take, which is what
    /// let a take killed near the end lose everything before it too. `nil` whenever the file could
    /// not even be opened.
    private var streamingSent: StreamingRecordingFile?

    private var peakAmplitude: Double = 0
    private var levelSum: Double = 0
    private var levelCount: Int = 0
    /// Whether the microphone route was narrowband when the take began — judged on the hardware
    /// rate, read back by `persistRecording()`.
    private var currentNarrowband = false
    private static let sampleRate = VoiceSocketProtocol.audioUplinkHz

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

        let earconPlayer = EarconPlayer(sessionPlayer: EarconSessionPlayer())
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
                },
                silenceGate: { MainActor.assumeIsolated { settingsStore.silenceGate } },
                device: { MainActor.assumeIsolated { VoiceDevice.current() } },
                log: { line in AppVoiceDiagnosticsLog.shared.log(.info, .gate, line) }
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

    var canStart: Bool { !isStarting && voiceSession.canStart }

    // MARK: - Start / stop

    /// `draftKey` names the draft the take dictates into — a session id, or the new-session
    /// composer's key. A live take writes its words there as they arrive; a batch take writes
    /// nothing until the server's result comes back.
    ///
    /// `preText` is what is already in the field; the transcript is appended to it rather than
    /// replacing it. Passed in rather than read from `drafts` here so the caller's own idea of
    /// what is in the field — which may include an edit still inside the flush debounce — wins.
    func start(draftKey: String, preText: String, sttMode: VoiceSttMode = .live) async {
        await beginTake(draftKey: draftKey, preText: preText, standaloneName: nil, sttMode: sttMode)
    }

    /// A recording not tied to a session: a meeting, a thought while driving, anything meant to
    /// be reviewed later. Its result lands on the recording and nowhere else; a batch one with the
    /// server unreachable is simply uploaded once it can be.
    func startStandalone(name: String, sttMode: VoiceSttMode) async {
        await beginTake(draftKey: nil, preText: "", standaloneName: name, sttMode: sttMode)
    }

    private func beginTake(draftKey: String?, preText: String, standaloneName: String?, sttMode: VoiceSttMode) async {
        guard !isStarting, voiceSession.canStart else { return }
        isStarting = true
        defer { isStarting = false }
        setupFailure = nil
        activeDraftKey = draftKey
        activeStandaloneName = standaloneName
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
        AppVoiceDiagnosticsLog.shared.log(
            .info, .mode,
            "\(standaloneName == nil ? "microphone" : "standalone") take started stt_mode=\(sttMode.wireValue)")
        let hardwareRate = capture.hardwareSampleRate
        // Told once, at the start of the take — matching the web's `startRecording`, which warns
        // here rather than waiting for `RecordingsSheet` to show it after the fact. Nothing
        // downstream can undo a narrowband route; the only useful move is naming what is costing
        // the accuracy while there is still time to disconnect it.
        currentNarrowband = VoiceAudioRatePolicy.isNarrowband(rate: hardwareRate)
        if currentNarrowband {
            toasts.show(
                "Mic is narrowband (\(hardwareRate / 1000) kHz, \(currentInputLabel())) — "
                    + "transcription will be poor. Disconnect the headset to use the phone mic.")
        }
        openStreamingFile(id: takeId)
        wireCaptureCallbacks()
        // Written before the first sample: a kill at any point after this leaves a ledger that
        // names the server-side take, so the launch pass seals and uploads it like any other.
        let ledger = TranscriptLedger(
            takeId: takeId, mode: standaloneName == nil ? .microphone : .offline, sampleRate: Self.sampleRate,
            draftKey: draftKey, preText: preText,
            serverTake: PendingServerTake(
                mode: sttMode, standalone: standaloneName != nil, standaloneName: standaloneName))
        activeLedger = ledger
        try? LedgerFile.write(ledger, to: audioStorage.ledgerURL(id: takeId))

        let startTask = Task {
            await voiceSession.start(
                draftKey: draftKey, takeId: takeId, sttMode: sttMode, standalone: standaloneName != nil)
        }
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
            try capture.start()
            isCapturing = true
            beginCaptureWatchdog()
            sessionWatcherTask?.cancel()
            sessionWatcherTask = Task { [weak self] in await self?.watchForSessionEndingOnItsOwn() }
            ledgerTask?.cancel()
            ledgerTask = Task { [weak self] in await self?.runLedgerLoop(takeId: takeId) }
            liveTextTask?.cancel()
            if let draftKey, sttMode == .live {
                liveTextTask = Task { [weak self] in await self?.runLiveTextLoop(takeId: takeId, draftKey: draftKey) }
            } else {
                liveTextTask = nil
            }
        } catch {
            // `openStreamingFile` above already opened this take's files — without persisting
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

    /// The one place a finished take's local state is torn down, called from `persistRecording()`
    /// because that is the single funnel every ending goes through — the user's tap, a lost
    /// connection, an interruption nothing could resume.
    ///
    /// One last live text write catches whatever landed between the live text loop's final tick
    /// and the take ending. Then the ledger is folded one last time and the take's server-side
    /// record fixed: its length, its withheld stretches, the words written into the draft, and
    /// whether anything is still owed. A live take whose receipt said everything is in, with every
    /// frame applied and every sample acknowledged, is complete; every other ending — the deadline,
    /// a dead socket, leaving, a held send, a batch take — leaves it owed, and the server's result
    /// is fetched once it exists (`runBackfillLoop`).
    private func finishLiveText() {
        chunkConsumerTask?.cancel()
        chunkConsumerTask = nil
        chunkContinuation?.finish()
        chunkContinuation = nil
        ledgerTask?.cancel()
        ledgerTask = nil
        liveTextTask?.cancel()
        liveTextTask = nil
        if let takeId = currentTakeId, let draftKey = activeDraftKey, voiceSession.sttMode == .live {
            applyLiveTakeText(takeId: takeId, draftKey: draftKey, newText: voiceSession.composedText)
        }
        if let takeId = currentTakeId, let base = activeLedger, base.takeId == takeId {
            var folded = Self.foldAckedRange(
                into: base, acknowledged: voiceSession.acknowledgedRanges, capturedUpTo: sealedLength,
                liveText: voiceSession.committedLiveText)
            let complete = isCleanlyComplete(takeId: takeId, ledger: folded)
            if complete { folded = folded.markingDelivered() }
            if var server = folded.serverTake {
                server.capturedSamples = sealedLength
                server.withheld = voiceSession.withheldRanges
                server.insertedText = lastWrittenTakeText[takeId]
                server.heldClientMessageId = heldClientMessageIds[takeId]
                server.settled = complete
                folded = folded.withServerTake(server)
            }
            activeLedger = folded
            try? LedgerFile.write(folded, to: audioStorage.ledgerURL(id: takeId))
            noteServerTake(takeId: takeId, ledger: folded)
        }
        activeDraftKey = nil
        activeStandaloneName = nil
        preVoiceText = ""
    }

    /// The take's length as its seal states it: what the uplink counted, which is every sample
    /// handed to it since the take started — or the file's own count for a take whose uplink
    /// never started at all.
    private var sealedLength: Int {
        max(voiceSession.capturedUpTo, streamingSent?.sampleCount ?? 0)
    }

    /// Nothing more to ask the server for: a live take whose `take_done` says every word is in,
    /// with no frame lost and nothing captured left unacknowledged.
    private func isCleanlyComplete(takeId: String, ledger: TranscriptLedger) -> Bool {
        guard voiceSession.sttMode == .live, heldClientMessageIds[takeId] == nil,
            let done = voiceSession.lastTakeDone, done.takeId == takeId,
            [VoiceTakeEndedReason.committed, VoiceTakeEndedReason.recovered, VoiceTakeEndedReason.empty]
                .contains(done.ended),
            voiceSession.highestAppliedSeq >= done.finalSeq
        else { return false }
        return ledger.gaps.isEmpty
    }

    /// Watches `voiceSession.composedText` and writes it into the draft as it grows — polling
    /// rather than reacting to `@Observable` directly, matching every other loop in this file that
    /// watches this session from outside a SwiftUI view body. 150ms is comfortably faster than
    /// ElevenLabs' own partial cadence (100-300ms), so a burst of partials never visibly lags.
    private func runLiveTextLoop(takeId: String, draftKey: String) async {
        var lastComposed = ""
        while !Task.isCancelled, voiceSession.state != .idle {
            let composed = voiceSession.composedText
            if composed != lastComposed {
                lastComposed = composed
                applyLiveTakeText(takeId: takeId, draftKey: draftKey, newText: composed)
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// What every take's own text last written into a draft looked like — `DraftHeal`'s own
    /// `previousInsertedText`, so the next write can find and replace it in place rather than
    /// appending a duplicate. Keyed by take id; a handful of entries at most; not pruned, since a
    /// session's whole lifetime of takes is small enough that this costs nothing to keep around.
    private var lastWrittenTakeText: [String: String] = [:]

    /// Live assembly's own append-or-heal rule: on this take's first write **in this process**,
    /// appends after `preVoiceText`; every write after that heals the previous insertion in place.
    /// Never used for backfill (`healBackfilledTakeText(takeId:draftKey:newText:)`), which cannot
    /// assume an empty `lastWrittenTakeText` means "nothing is there yet" — a crash-recovered take
    /// can hold live-written text from a process that no longer exists, and appending blindly
    /// there would duplicate it.
    private func applyLiveTakeText(takeId: String, draftKey: String, newText: String) {
        guard !newText.isEmpty, heldClientMessageIds[takeId] == nil else { return }
        let prefixed = "\(VoiceRecordingResult.sttPrefix)\(newText)"
        guard let previous = lastWrittenTakeText[takeId], !previous.isEmpty else {
            let combined = preVoiceText.isEmpty ? prefixed : "\(preVoiceText) \(prefixed)"
            drafts.setDraftText(key: draftKey, text: combined)
            lastWrittenTakeText[takeId] = prefixed
            return
        }
        if case let .replaced(updated) = DraftHeal.heal(
            currentDraftText: drafts.draft(for: draftKey).text, previousInsertedText: previous, healedText: prefixed)
        {
            drafts.setDraftText(key: draftKey, text: updated)
        }
        // Edited or sent since (`.notFound`): the take's own text is gone from the draft, and
        // nothing here may resurrect it — but the take keeps dictating, so its NEXT write should
        // still be judged against what THIS write would have looked like, not against nothing.
        lastWrittenTakeText[takeId] = prefixed
    }

    /// Backfill's own rule: never appends, whatever `lastWrittenTakeText` holds. Only ever
    /// replaces a previous insertion this process itself made, or does nothing — the accepted
    /// limitation for a take recovered at launch (see this run's own report).
    private func healBackfilledTakeText(takeId: String, draftKey: String, newText: String) {
        guard !newText.isEmpty else { return }
        let prefixed = "\(VoiceRecordingResult.sttPrefix)\(newText)"
        let previous = lastWrittenTakeText[takeId] ?? ""
        defer { lastWrittenTakeText[takeId] = prefixed }
        guard
            case let .replaced(updated) = DraftHeal.heal(
                currentDraftText: drafts.draft(for: draftKey).text, previousInsertedText: previous, healedText: prefixed
            )
        else { return }
        drafts.setDraftText(key: draftKey, text: updated)
    }

    /// Gives up the take without touching the draft — for the failures that happen before any
    /// audio was captured, where the field should read exactly as it did before the tap.
    private func releaseTakeWithoutText() {
        activeDraftKey = nil
        activeStandaloneName = nil
        preVoiceText = ""
    }

    /// Turns what the uplink knows is settled — stored by the backend, or withheld — into what
    /// the ledger's gap derivation understands: textless `.live` segments over those ranges, since
    /// such a segment records delivery, and the take's committed words as `liveText`, which is
    /// where a recording's transcript and a healed draft read them from. The whole set is passed
    /// every call rather than only what is new: `SeamMerge.merge` coalesces it with the coverage
    /// the ledger already had, so a fold can never regress even if a call is skipped.
    private static func foldAckedRange(
        into ledger: TranscriptLedger, acknowledged: [SampleRange], capturedUpTo: Int, liveText: [LiveTextSegment]
    ) -> TranscriptLedger {
        ledger.folding(
            liveSegments: acknowledged.map { Segment(range: $0, text: "", source: .live) }, capturedUpTo: capturedUpTo,
            newlyAcknowledged: acknowledged, liveText: liveText
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

    /// Watches what the live session has settled and writes the ledger whenever it changes —
    /// polling rather than reacting to `@Observable` directly, matching every other loop that
    /// watches this same session from outside a SwiftUI view body. One second is coarse on
    /// purpose: nothing here needs sub-second freshness, only to notice a new gap soon enough to
    /// start uploading it.
    private func runLedgerLoop(takeId: String) async {
        var lastAcknowledged: [SampleRange] = []
        var lastLiveTextCount = 0
        while !Task.isCancelled, voiceSession.state != .idle {
            let acknowledged = voiceSession.acknowledgedRanges
            let liveText = voiceSession.committedLiveText
            if acknowledged != lastAcknowledged || liveText.count != lastLiveTextCount {
                lastAcknowledged = acknowledged
                lastLiveTextCount = liveText.count
                persistLedger(takeId: takeId)
            }
            try? await Task.sleep(for: .seconds(1))
        }
        // One last write regardless of how the loop above ended; `finishLiveText()`'s own
        // synchronous fold is what catches the take's very last moment.
        persistLedger(takeId: takeId)
    }

    /// Folds what the uplink has settled into `takeId`'s ledger (`foldAckedRange` — the same fold
    /// `finishLiveText()` uses) and writes it — audio is already on disk by the time this runs, so
    /// the ledger is never ahead of it. A new gap schedules the take's upload loop and sounds the
    /// "still catching up" cue.
    private func persistLedger(takeId: String) {
        guard let base = activeLedger, base.takeId == takeId else { return }
        let final = Self.foldAckedRange(
            into: base, acknowledged: voiceSession.acknowledgedRanges, capturedUpTo: voiceSession.capturedUpTo,
            liveText: voiceSession.committedLiveText)
        activeLedger = final
        try? LedgerFile.write(final, to: audioStorage.ledgerURL(id: takeId))
        // The live edge — sent, not yet acknowledged — is always a gap for a moment; only a gap
        // the socket can no longer close is worth a cue.
        let frontier = voiceSession.uplinkFrontier
        let closedGapCount = final.gaps.filter { $0.range.lowerBound < frontier }.count
        guard closedGapCount > 0 else { return }
        if closedGapCount > base.gaps.filter({ $0.range.lowerBound < frontier }).count {
            feedbackNotifier.handle(.gapOpened)
        }
        scheduleBackfillIfNeeded(takeId: takeId)
    }

    /// One backfill loop per take still owed something. A second call for a take already being
    /// worked is a no-op — `runBackfillLoop` re-reads the ledger on every pass, so there is never
    /// a reason for two loops on the same take to exist at once.
    private func scheduleBackfillIfNeeded(takeId: String) {
        guard backfillTasks[takeId] == nil else { return }
        backfillTasks[takeId] = Task { [weak self] in
            await self?.runBackfillLoop(takeId: takeId)
            self?.backfillTasks[takeId] = nil
        }
    }

    /// Runs until the take owes nothing, reading the ledger fresh each pass — which is what lets
    /// the very same loop serve the take still recording (read from `activeLedger`) and one
    /// `reconcileTakes()` found unfinished at launch (read from disk).
    ///
    /// A take the server owns (`serverTake`) uploads, while it records, every gap the socket can
    /// no longer close; once it has stopped, `OwedTakeDriver` seals it, uploads what the server
    /// lists as missing and waits for the result. A take from before takes lived on the server
    /// heals its gaps by plain re-transcription.
    ///
    /// 🚨 Gated on `backfillGate(now:)`, never `state` — `state` answers "is a live socket open
    /// and trustworthy right now", which stays `.offline`/`.connecting` with no take recording at
    /// all. `backfillGate` only needs the network path itself satisfied with no recent failure —
    /// knowable with no socket open — and reads fresh off `Date()` on every poll.
    private func runBackfillLoop(takeId: String) async {
        while !Task.isCancelled {
            guard let ledger = readLedger(takeId: takeId) else { return }
            if let server = ledger.serverTake {
                if takeId == currentTakeId {
                    await uploadClosedGapsWhileRecording(takeId: takeId, ledger: ledger)
                    continue
                }
                guard server.isOwed else { return }
                await resolveOwedTake(takeId: takeId, ledger: ledger, server: server)
                return
            }
            guard ledger.gaps.contains(where: { !$0.demoted }) else { return }
            await runLegacyBackfillPass(takeId: takeId, ledger: ledger)
        }
    }

    /// One pass for the take still recording: whatever the socket will never deliver — older
    /// than the uplink's frontier and unacknowledged — goes up into the take now, so little is
    /// left to send when the take stops.
    private func uploadClosedGapsWhileRecording(takeId: String, ledger: TranscriptLedger) async {
        let frontier = voiceSession.uplinkFrontier
        let ranges = ledger.gaps.compactMap { gap -> SampleRange? in
            let upper = min(gap.range.upperBound, frontier)
            return gap.range.lowerBound < upper ? gap.range.lowerBound..<upper : nil
        }
        guard !ranges.isEmpty, connectionHealthBox.value.backfillGate(now: Date()) == .stable else {
            try? await Task.sleep(for: .seconds(Self.backfillPollSeconds))
            return
        }
        let result = await OwedTakeDriver.upload(
            ranges, takeId: takeId, sampleRate: ledger.sampleRate, api: apiClient, audioReader: audioStorage,
            device: VoiceDevice.deviceName)
        switch result {
        case .uploaded:
            guard let current = readLedger(takeId: takeId) else { return }
            let applied = current.applyingBackfill(newSegments: [], resolved: ranges, failed: [])
            if takeId == currentTakeId { activeLedger = applied }
            try? LedgerFile.write(applied, to: audioStorage.ledgerURL(id: takeId))
        case let .refused(reason):
            AppVoiceDiagnosticsLog.shared.log(.warning, .mode, "take \(takeId) upload refused: \(reason)")
            try? await Task.sleep(for: .seconds(Self.standaloneRetrySeconds))
        case .retryLater:
            try? await Task.sleep(for: .seconds(Self.backfillPollSeconds))
        }
    }

    /// Sees a stopped take through to its result and applies it here.
    private func resolveOwedTake(takeId: String, ledger: TranscriptLedger, server: PendingServerTake) async {
        guard let seal = server.seal(draftKey: ledger.draftKey, device: VoiceDevice.deviceName) else { return }
        let recorded = audioStorage.clampedCapturedSampleCount(id: takeId) ?? 0
        let outcome = await OwedTakeDriver.resolve(
            takeId: takeId, seal: seal, sampleRate: ledger.sampleRate, recordedSamples: recorded, api: apiClient,
            audioReader: audioStorage, sleep: { try? await Task.sleep(for: $0) },
            onTake: { [weak self] take in await self?.noteTakeState(takeId: takeId, state: take.state) })
        switch outcome {
        case let .done(take):
            applyTakeResult(takeId: takeId, take: take)
        case let .failed(take):
            AppVoiceDiagnosticsLog.shared.log(
                .warning, .mode, "take \(takeId) failed on the server: \(take.failure?.detail ?? "-")")
            noteTakeState(takeId: takeId, state: .failed)
        case let .stuck(reason):
            AppVoiceDiagnosticsLog.shared.log(.warning, .mode, "take \(takeId) stuck: \(reason)")
        case .cancelled:
            break
        }
    }

    /// The server's state for an owed take, kept on its ledger for the recordings list.
    private func noteTakeState(takeId: String, state: VoiceTakeState) {
        guard let ledger = readLedger(takeId: takeId), var server = ledger.serverTake, server.lastState != state
        else { return }
        server.lastState = state
        writeServerTake(takeId: takeId, ledger: ledger.withServerTake(server))
    }

    /// A finished take's text, applied: healed into its draft unless a send carried it, and
    /// stored on its recording either way. The ledger then owes nothing — every sample is on the
    /// server — so the take's audio falls under the ordinary retention rule.
    private func applyTakeResult(takeId: String, take: VoiceTake) {
        guard let ledger = readLedger(takeId: takeId), var server = ledger.serverTake else { return }
        let text = take.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !server.standalone, server.heldClientMessageId == nil, take.heldMessage == nil,
            let draftKey = ledger.draftKey,
            let healed = TakeResultHeal.apply(
                currentDraftText: drafts.draft(for: draftKey).text, previousInsertedText: server.insertedText,
                takeText: text)
        {
            drafts.setDraftText(key: draftKey, text: healed)
            lastWrittenTakeText[takeId] = "\(VoiceRecordingResult.sttPrefix)\(text)"
        }
        server.settled = true
        server.lastState = .done
        let captured = server.capturedSamples ?? ledger.capturedUpTo
        let final = ledger.applyingBackfill(newSegments: [], resolved: captured > 0 ? [0..<captured] : [], failed: [])
            .markingDelivered().withServerTake(server)
        writeServerTake(takeId: takeId, ledger: final)
        if let existing = settingsStore.recordings.first(where: { $0.id == takeId }) {
            settingsStore.updateRecording(
                existing.withTranscript(
                    text.isEmpty ? existing.transcript : text, source: server.mode == .batch ? .batch : .live,
                    complete: take.ended != .unavailable, transcription: Self.transcriptionMeta(for: final)))
        }
        if !text.isEmpty { feedbackNotifier.handle(.backfillCompleted) }
    }

    /// Writes a ledger whose server-side take changed, and keeps ``owedTakes`` in step with it.
    private func writeServerTake(takeId: String, ledger: TranscriptLedger) {
        if takeId == currentTakeId { activeLedger = ledger }
        try? LedgerFile.write(ledger, to: audioStorage.ledgerURL(id: takeId))
        noteServerTake(takeId: takeId, ledger: ledger)
    }

    private func noteServerTake(takeId: String, ledger: TranscriptLedger) {
        if let server = ledger.serverTake, server.isOwed {
            owedTakes[takeId] = OwedTakeSummary(takeId: takeId, draftKey: ledger.draftKey, serverTake: server)
        } else {
            owedTakes[takeId] = nil
        }
    }

    /// The plain re-transcription pass for a take from before takes lived on the server.
    private func runLegacyBackfillPass(takeId: String, ledger: TranscriptLedger) async {
        let health = connectionHealthBox.value.backfillGate(now: Date())
        guard health == .stable else {
            try? await Task.sleep(for: .seconds(Self.backfillPollSeconds))
            return
        }
        let requests = BackfillPlanner.plan(
            gaps: ledger.gaps, sampleRate: ledger.sampleRate, capturedUpTo: ledger.capturedUpTo, health: health)
        guard !requests.isEmpty else {
            try? await Task.sleep(for: .seconds(Self.backfillPollSeconds))
            return
        }

        var newSegments: [Segment] = []
        var resolved: [SampleRange] = []
        var failed: [(range: SampleRange, error: String, countsTowardDemotion: Bool)] = []
        let sampleRate = ledger.sampleRate
        for request in requests {
            guard connectionHealthBox.value.backfillGate(now: Date()) == .stable else { break }
            let outcome = await BatchBackfiller.run(
                request, sampleRate: sampleRate, audioReader: audioStorage, takeId: takeId,
                transcribe: { [weak self] wav in
                    guard let self else { throw VoiceSocketTransportError.notConnected }
                    return try await self.batchTranscribe(wav: wav)
                }
            )
            switch outcome {
            case let .segment(segment):
                newSegments.append(segment)
                resolved.append(contentsOf: request.gapRanges)
            case .noSpeechDetected:
                resolved.append(contentsOf: request.gapRanges)
            case let .failed(error, countsTowardDemotion):
                failed.append(
                    contentsOf: request.gapRanges.map {
                        (range: $0, error: error, countsTowardDemotion: countsTowardDemotion)
                    })
            }
        }
        await applyBackfillOutcome(takeId: takeId, newSegments: newSegments, resolved: resolved, failed: failed)
        // A pass that only failed for the link's reasons waits like an outage, not like a retry.
        try? await Task.sleep(for: failed.isEmpty ? .milliseconds(300) : .seconds(Self.backfillPollSeconds))
    }

    /// Applies one backfill pass against the ledger's *current* state
    /// (`TranscriptLedger.applyingBackfill` — never the snapshot `runBackfillLoop` started
    /// reading from, which its own network round trips can leave stale), updates the take's
    /// `RecordingMeta` coverage, and — for a take that has already ended — heals the take's own
    /// reassembled text (live segments, batch segments and any still-open gap marker, in order)
    /// into the draft via `healBackfilledTakeText(takeId:draftKey:newText:)`.
    ///
    /// A take still actively recording never reaches the heal below: `applyLiveTakeText` already
    /// writes it on every tick, and a batch pass only ever fires for a gap the live path missed (a
    /// drop longer than the bus's own reconnect grace window) — see `VoiceUplinkSession`'s own doc
    /// comment.
    private func applyBackfillOutcome(
        takeId: String, newSegments: [Segment], resolved: [SampleRange],
        failed: [(range: SampleRange, error: String, countsTowardDemotion: Bool)]
    ) async {
        guard let ledger = readLedger(takeId: takeId) else { return }
        var final = ledger.applyingBackfill(newSegments: newSegments, resolved: resolved, failed: failed)

        if takeId == currentTakeId {
            activeLedger = final
        } else if final.mode == .microphone, !newSegments.isEmpty, let draftKey = final.draftKey {
            let assembled = VoiceTextAssembly.assembledText(from: final)
            if !assembled.isEmpty {
                healBackfilledTakeText(takeId: takeId, draftKey: draftKey, newText: assembled)
                if final.gaps.isEmpty { final = final.markingDelivered() }
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

    /// The one caller of the backend's own batch transcription route — it holds the ElevenLabs
    /// key server-side and returns plain text only, no word-level timestamps (unlike the
    /// ElevenLabs-era direct call this replaces). `BatchBackfiller`/`SeamMerge` already have a
    /// no-timestamps fallback (a text suffix/prefix trim capped at eight words) for exactly this
    /// case, so an empty `words` array here degrades gracefully rather than needing its own path.
    private func batchTranscribe(wav: Data) async throws -> (text: String, words: [Word]) {
        let text = try await apiClient.transcribeVoiceTake(takeId: UUID().uuidString, wav: wav)
        return (text: text, words: [])
    }

    /// A take's `RecordingMeta.transcription` after a ledger change — what the recordings screen
    /// reads to show coverage without opening the ledger itself. A no-op for a take
    /// `SettingsStore` never saved (still mid-take, or evicted since).
    private func updateRecordingMeta(takeId: String, ledger: TranscriptLedger) {
        guard let existing = settingsStore.recordings.first(where: { $0.id == takeId }) else { return }
        let transcript = VoiceTextAssembly.assembledText(from: ledger)
        let updated = existing.withTranscript(
            transcript.isEmpty ? existing.transcript : transcript, source: existing.transcriptSource,
            complete: existing.transcriptComplete, transcription: Self.transcriptionMeta(for: ledger))
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
                if case .pathSatisfied(true) = event {
                    if self.voiceSession.state == .reconnecting { self.voiceSession.retryReconnectNow() }
                    self.resumeOwedTakes()
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

    /// Leaving, typing or tapping during Finishing: the wait ends, the take does not. The gate
    /// carried the seal, the server finishes the take on its own, and its result is fetched and
    /// healed into the draft (`runBackfillLoop`).
    func stopWaiting() {
        if isStopRequested && voiceSession.state != .stopping {
            stopWaitingRequestedDuringTail = true
            return
        }
        voiceSession.stopWaiting()
    }

    // MARK: - Held send

    /// What a Send that waits on a take carries: the take and where its words sit, plus the text
    /// the composer showed at the press — read in the same instant, so the two agree.
    struct HeldSend: Sendable {
        let heldTake: HeldTake
        let message: String
    }

    /// Whether Send in `draftKey`'s composer would wait on a take — this composer's take still
    /// finishing, or an owed one whose words the message carries. Send is enabled then even with
    /// nothing typed: a batch take's words are on their way.
    func sendWaitsOnTake(draftKey: String) -> Bool {
        if activeDraftKey == draftKey, state == .stopping { return true }
        return OwedTakeSummary.heldSendCandidate(
            among: Array(owedTakes.values), draftKey: draftKey, composerText: drafts.draft(for: draftKey).text) != nil
    }

    /// A batch take of `draftKey`'s composer being transcribed — what the composer labels.
    func isTranscribingBatch(draftKey: String) -> Bool {
        owedTakes.values.contains { $0.draftKey == draftKey && $0.serverTake.mode == .batch }
    }

    /// Ties the send `clientMessageId` to the take its message is waiting on, and stops waiting
    /// for that take here: the server composes the message from `before`, the take's final text
    /// and `after` once the take is done. `nil` when there is no such take, or its words are no
    /// longer where they were written — the send is then an ordinary one, and the take's result
    /// comes back into the draft.
    func holdTakeForSend(draftKey: String, clientMessageId: String) async -> HeldSend? {
        if activeDraftKey == draftKey, state == .stopping, let takeId = currentTakeId {
            // Still in the stop tail: the length the seal states is known once capture is drained
            // and the gate is closing.
            var waited = 0
            while isStopRequested, voiceSession.state != .stopping, voiceSession.state != .idle, waited < 150 {
                try? await Task.sleep(for: .milliseconds(20))
                waited += 1
            }
            let mode = voiceSession.sttMode
            let inserted = mode == .batch ? nil : lastWrittenTakeText[takeId]
            guard
                let plan = Self.heldSend(
                    takeId: takeId, mode: mode, composerText: drafts.draft(for: draftKey).text, insertedText: inserted,
                    capturedSamples: sealedLength, withheld: voiceSession.withheldRanges)
            else {
                stopWaiting()
                return nil
            }
            heldClientMessageIds[takeId] = clientMessageId
            stopWaiting()
            return plan
        }
        let composerText = drafts.draft(for: draftKey).text
        guard
            let owed = OwedTakeSummary.heldSendCandidate(
                among: Array(owedTakes.values), draftKey: draftKey, composerText: composerText),
            let captured = owed.serverTake.capturedSamples,
            let plan = Self.heldSend(
                takeId: owed.takeId, mode: owed.serverTake.mode, composerText: composerText,
                insertedText: owed.serverTake.mode == .batch ? nil : owed.serverTake.insertedText,
                capturedSamples: captured, withheld: owed.serverTake.withheld),
            let ledger = readLedger(takeId: owed.takeId)
        else { return nil }
        var server = owed.serverTake
        server.heldClientMessageId = clientMessageId
        writeServerTake(takeId: owed.takeId, ledger: ledger.withServerTake(server))
        return plan
    }

    private static func heldSend(
        takeId: String, mode: VoiceSttMode, composerText: String, insertedText: String?, capturedSamples: Int,
        withheld: [SampleRange]
    ) -> HeldSend? {
        guard let split = HeldTakeSplit.split(composerText: composerText, insertedText: insertedText) else {
            return nil
        }
        let shown = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        return HeldSend(
            heldTake: HeldTake(
                takeId: takeId, mode: mode, before: split.before, after: split.after, capturedSamples: capturedSamples,
                withheld: withheld.isEmpty ? nil : withheld),
            // A batch take shows no words while it records, so a send of nothing but the take
            // still needs a bubble to show and a text to fall back on.
            message: shown.isEmpty ? "\(VoiceRecordingResult.sttPrefix)…" : shown)
    }

    /// Picks owed takes back up — on foreground, and whenever the network path returns — so a
    /// take that stalled in the background or offline does not wait for the next launch.
    func resumeOwedTakes() {
        for takeId in owedTakes.keys { scheduleBackfillIfNeeded(takeId: takeId) }
    }

    // MARK: - Re-transcription

    struct RecordingAudioMissing: LocalizedError {
        var errorDescription: String? { "Recording audio data not found." }
    }

    /// Recordings a batch pass is running for right now — what the list's spinner reads.
    private(set) var retranscribingIds: Set<String> = []
    /// One automatic transcription loop per standalone recording still without its batch text.
    private var standaloneTranscriptionTasks: [String: Task<Void, Never>] = [:]
    private static let standaloneRetrySeconds: TimeInterval = 30

    /// A fresh batch pass over the whole recording through the backend (which holds the
    /// ElevenLabs key), stored on the recording as its transcript. Never inserts anything
    /// anywhere — putting the text into a session is the transcript icon's job.
    func retranscribe(id: String) async throws {
        guard !retranscribingIds.contains(id) else { return }
        guard let totalSamples = audioStorage.clampedCapturedSampleCount(id: id),
            let sampleRate = audioStorage.sentHeader(id: id)?.sampleRate
        else { throw RecordingAudioMissing() }
        retranscribingIds.insert(id)
        defer { retranscribingIds.remove(id) }
        let storage = audioStorage
        let api = apiClient
        let text = try await RecordingRetranscription.run(
            totalSamples: totalSamples, sampleRate: sampleRate,
            read: { range in
                let pcm = try await storage.readSamples(id: id, range: WavByteRange.forSamples(range))
                return PcmWavWriter.samples(fromPCM16LE: pcm)
            },
            transcribe: { wav, previousText in
                try await api.transcribeVoiceTake(takeId: id, wav: wav, previousText: previousText)
            }
        )
        guard let existing = settingsStore.recordings.first(where: { $0.id == id }) else { return }
        settingsStore.updateRecording(
            existing.withTranscript(text.isEmpty ? nil : text, source: .batch, complete: true))
    }

    /// A standalone recording made before takes lived on the server has no take to resolve, so
    /// it is batch-transcribed as soon as the link allows — waiting out an offline stretch,
    /// retrying a failure — until it carries a batch transcript or is deleted. Nothing is
    /// persisted for this: the recording's own metadata says whether it is still owed one, and
    /// launch reconciliation re-schedules it.
    private func scheduleStandaloneTranscription(id: String) {
        guard standaloneTranscriptionTasks[id] == nil else { return }
        standaloneTranscriptionTasks[id] = Task { [weak self] in
            await self?.runStandaloneTranscription(id: id)
            self?.standaloneTranscriptionTasks[id] = nil
        }
    }

    private func runStandaloneTranscription(id: String) async {
        while !Task.isCancelled {
            guard let meta = settingsStore.recordings.first(where: { $0.id == id }),
                meta.transcriptSource != .batch
            else { return }
            guard connectionHealthBox.value.backfillGate(now: Date()) == .stable else {
                try? await Task.sleep(for: .seconds(Self.backfillPollSeconds))
                continue
            }
            do {
                try await retranscribe(id: id)
                return
            } catch {
                AppVoiceDiagnosticsLog.shared.log(
                    .warning, .mode, "standalone recording \(id) not transcribed yet: \(error)")
                try? await Task.sleep(for: .seconds(Self.standaloneRetrySeconds))
            }
        }
    }

    /// The recordings screen's "Transcribe now" — the one explicit "try again": a take the
    /// server gave up on is sent back to its resolver, a take from before takes lived on the
    /// server has its demoted gaps put back in the running, and either way the take's loop is
    /// running again.
    func transcribeRemainingGaps(id: String) {
        guard let ledger = readLedger(takeId: id) else { return }
        if let server = ledger.serverTake {
            guard server.isOwed else { return }
            Task {
                if server.lastState == .failed { _ = try? await apiClient.retryVoiceTake(takeId: id) }
                scheduleBackfillIfNeeded(takeId: id)
            }
            return
        }
        guard !ledger.gaps.isEmpty else { return }
        if ledger.gaps.contains(where: \.demoted) {
            try? LedgerFile.write(ledger.undemotingGaps(), to: audioStorage.ledgerURL(id: id))
        }
        scheduleBackfillIfNeeded(takeId: id)
    }

    /// Deletes a past recording by the user's own tap — distinct from the retention cap's automatic
    /// eviction, though both end at `onRecordingEvicted`, which is what actually removes the
    /// bytes.
    func deleteRecording(_ meta: RecordingMeta) {
        settingsStore.removeRecording(id: meta.id)
    }

    /// Stops the take and persists the recording (audio + metadata).
    ///
    /// The stop sequence every client shares: capture keeps running for a short tail after the
    /// press, then every captured chunk is drained into the uplink BEFORE it closes the gate — a
    /// chunk still queued when the uplink turned to finishing used to be dropped, and with it the
    /// last syllable. Only then does the uplink close the gate with the seal and wait for the
    /// take's receipt.
    func stop() async {
        guard isCapturing || voiceSession.state != .idle, !isStopRequested else { return }
        isStopRequested = true
        stopWaitingRequestedDuringTail = false
        defer {
            isStopRequested = false
            stopWaitingRequestedDuringTail = false
        }
        if isCapturing {
            try? await Task.sleep(for: .milliseconds(Self.stopTailMs))
        }
        capture.stop()
        isCapturing = false
        endCaptureWatchdog()
        await drainCapturedChunks()
        let finishStarted = Date()
        await voiceSession.stop(reason: .user, waitForReceipt: !stopWaitingRequestedDuringTail)
        let ended = voiceSession.lastTakeDone?.ended ?? voiceSession.lastTakeState?.wireValue ?? "none"
        let waitMs = Int(Date().timeIntervalSince(finishStarted) * 1000)
        AppVoiceDiagnosticsLog.shared.log(.info, .gate, "take finished ended=\(ended) wait_ms=\(waitMs)")
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)

        await persistRecording()
        AppVoiceDiagnosticsLog.shared.log(.info, .mode, "take stopped")
    }

    /// Hands every chunk capture has already delivered to the uplink and the take's file, in
    /// order, and waits until the last one is in. Capture must already be stopped, so nothing
    /// more can arrive behind it.
    private func drainCapturedChunks() async {
        chunkContinuation?.finish()
        chunkContinuation = nil
        await chunkConsumerTask?.value
        chunkConsumerTask = nil
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
    /// was already playing — the user's own expectation when a take or a call starts, the same
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshAvailableMicrophones()
                if self.isCapturing { await self.voiceSession.inputRouteChanged() }
            }
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
            // Converted to the socket's fixed rate whatever the hardware's own rate is now — a
            // route change while paused (an AirPod reconnecting, say) changes only the input side.
            try capture.start()
            isCapturing = true
            beginCaptureWatchdog()
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

    // MARK: - Capture wiring

    private func openStreamingFile(id: String) {
        peakAmplitude = 0
        levelSum = 0
        levelCount = 0
        streamingSent = StreamingRecordingFile(url: audioStorage.sentURL(id: id), sampleRate: Self.sampleRate)
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
            // so far is already on disk, and the user is told rather than discovering an hour later
            // that a recording they believed was running captured nothing.
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
    /// The output rate is the socket's fixed 16 kHz whatever the configuration change did to the
    /// input rate — the same rule as resuming after an interruption.
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
            try capture.start()
            lastChunkAt = Date()
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
        let standaloneName = activeStandaloneName
        let sttMode = voiceSession.sttMode
        finishLiveText()
        // Captured before the early returns below, and before `activeLedger` is cleared at the
        // end of this method — `nil` for a take that never got far enough to open a ledger.
        let takeLedger = activeLedger

        let sent = streamingSent
        streamingSent = nil
        sent?.finalize()
        let result = voiceSession.result
        // The captured samples are the take's own record of how long it ran — the uplink's wall
        // clock includes the time before the microphone opened and after it closed.
        let durationMs = Int(Double(sent?.sampleCount ?? 0) / Double(Self.sampleRate) * 1000)

        guard let timestampMs = takeTimestampMs else { return }
        takeTimestampMs = nil
        let id = RecordingMeta.id(forTimestampMs: timestampMs)

        guard durationMs > 0, sent?.hasData == true else {
            // Nothing worth keeping — `start()` already opened files for this id, so clean up the
            // stubs rather than leaving 44-byte orphans behind.
            await audioStorage.delete(id: id)
            activeLedger = nil
            owedTakes[id] = nil
            return
        }
        let averageLevel = levelCount > 0 ? levelSum / Double(levelCount) : 0
        let mic = MicDiagnostics(
            label: currentInputLabel(), trackSampleRate: Double(capture.hardwareSampleRate),
            contextSampleRate: Double(capture.hardwareSampleRate), channelCount: 1,
            echoCancellation: nil, noiseSuppression: nil, autoGainControl: nil, userAgent: "iOS"
        )
        let transcript = takeLedger.map { VoiceTextAssembly.assembledText(from: $0) }.flatMap { $0.isEmpty ? nil : $0 }
        let owed = takeLedger?.serverTake?.isOwed ?? false
        let meta = RecordingMeta(
            timestampMs: timestampMs,
            durationMs: Double(durationMs),
            sampleRate: Double(Self.sampleRate),
            mic: mic,
            endedBy: result.endedBy,
            transcript: transcript,
            transcriptSource: transcript == nil ? nil : .live,
            transcriptComplete: sttMode == .batch ? nil : !owed,
            levels: LevelStats(
                peak: peakAmplitude, rms: averageLevel, clippedSamples: 0, totalSamples: sent?.sampleCount ?? 0
            ),
            narrowband: currentNarrowband,
            mutedMs: result.mutedMs > 0 ? Double(result.mutedMs) : nil,
            transcription: takeLedger.map(Self.transcriptionMeta(for:)),
            name: standaloneName,
            mode: standaloneName == nil ? nil : .offline,
            sttMode: sttMode
        )
        settingsStore.saveRecording(meta)
        // A take reconnecting endlessly, or whose transcription stopped for a fatal reason, was
        // already told about it at the moment it happened — through `feedbackNotifier`. Nothing
        // here ends a take for a connection reason, so there is no separate notice to send here.
        activeLedger = nil
        if owed { scheduleBackfillIfNeeded(takeId: id) }
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
                id: id, sampleRate: header.sampleRate, dataSize: header.dataSize)
            guard let meta = RecordingReconciliation.metadata(for: take) else { continue }
            settingsStore.saveRecording(meta)
        }

        for id in allIds.sorted() where orphanIds.contains(id) || audioStorage.hasLedger(id: id) {
            reconcileLedger(id: id)
        }

        for meta in settingsStore.recordings
        where meta.mode == .offline && meta.transcriptSource != .batch && !audioStorage.hasLedger(id: meta.id) {
            scheduleStandaloneTranscription(id: meta.id)
        }
    }

    /// One take's ledger against what its header's clamped sample count says was actually
    /// captured — the durable-pipeline half of the launch pass. A kill mid-take leaves audio the
    /// ledger's last write does not cover; this is what turns that into a gap a backfill loop can
    /// close, the same rule `TranscriptLedger.derivedGaps` applies while a take is still live.
    ///
    /// A server-side take is resumed whatever its gaps: one the app was killed in the middle of
    /// is sealed at what reached the file, and one already owed carries on where it was.
    private func reconcileLedger(id: String) {
        guard let capturedUpTo = audioStorage.clampedCapturedSampleCount(id: id), capturedUpTo > 0,
            let sampleRate = audioStorage.sentHeader(id: id)?.sampleRate, sampleRate > 0
        else { return }
        let existing = LedgerFile.read(from: audioStorage.ledgerURL(id: id))
        if let existing, var server = existing.serverTake {
            guard !server.settled else { return }
            if server.capturedSamples == nil { server.capturedSamples = capturedUpTo }
            writeServerTake(takeId: id, ledger: existing.withServerTake(server))
            scheduleBackfillIfNeeded(takeId: id)
            return
        }
        let reconciled = RecordingReconciliation.reconcile(
            ledger: existing, takeId: id, sampleRate: sampleRate, capturedSampleCount: capturedUpTo)
        guard !reconciled.gaps.isEmpty else { return }
        try? LedgerFile.write(reconciled, to: audioStorage.ledgerURL(id: id))
        updateRecordingMeta(takeId: id, ledger: reconciled)
        scheduleBackfillIfNeeded(takeId: id)
    }
}
