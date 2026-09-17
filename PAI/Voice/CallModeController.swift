import Foundation
import PAIKit

/// Drives call mode end to end: entering and leaving, the shared microphone tap, the offline and
/// fallback command channels, the reply feed, and speech output — everything `CallModeStore`
/// itself deliberately does not own (see that type's own doc comment).
///
/// One instance for the app, alongside `VoiceRecorderController` — never per screen, so a call
/// outlives the screen that started it exactly as a microphone-mode take does, and so
/// `VoiceIntentBridge`'s Action Button handler can reach whichever call is running without a
/// screen mounted at all.
///
/// **The audio/transcription design:** call mode's own live transcription runs through a fresh
/// `VoiceRecordingSession` per "collecting" cycle (one per `start`→`stop`/`send`), not the single
/// continuous session microphone mode uses for a whole take. Each cycle addresses its own audio
/// from zero, exactly as a microphone-mode take does — never fed a non-zero starting offset, so
/// every internal invariant that type already relies on holds unchanged. While a cycle is open,
/// its `committedSegments` and `acknowledgedRanges` are both shifted (`CallCycleAddressing`) by
/// however many samples the call's own ledger has already collected across every earlier cycle
/// and written through — reusing `VoiceRecorderController`'s own ledger-write and backfill
/// machinery directly (`persistExternalLedger`/`beginExternalTake`), never a second copy of
/// either. That is also what makes a connection drop mid-cycle heal exactly as a microphone-mode
/// take's does: audio keeps being captured to disk regardless of the socket, `capturedUpTo` keeps
/// advancing with it (`VoiceRecordingSession.ingestAudioChunk`'s own contract), and whatever
/// stretch a drop leaves unacknowledged derives as an ordinary gap the same
/// `BackfillPlanner`/`BatchBackfiller` already heal for microphone mode, bounded to
/// `TranscriptLedger.collecting` — the one field `.call` mode's own gap derivation bounds itself
/// to, kept current here on every write.
///
/// **What this does not build:** speaking a blocker the session is waiting on out loud — flagged
/// elsewhere rather than guessed at under time pressure.
@MainActor
@Observable
final class CallModeController {
    /// The app's one instance, for the debug bridge — the same `weak var current` shape
    /// `TranscriptCollectionViewController` already uses, since this is likewise "one instance
    /// for the app" rather than something a route can reach through a view hierarchy. Answers
    /// what the plus menu's call-mode entry would show right now, the JSON counterpart to
    /// screenshotting a native `Menu`, which nothing here can force open.
    #if DEBUG
        static weak var current: CallModeController?
    #endif

    private(set) var store: CallModeStore?
    private(set) var speech: SpeechOutputSession?

    private let controller: VoiceRecorderController
    private let apiClient: PaiApiClient
    private let requestFactory: PaiRequestFactory
    private let transcript: TranscriptStore
    private let drafts: DraftStore
    private let settingsStore: SettingsStore
    private let wakeWordSettings: WakeWordSettingsStore

    private var speechOutput: SpeechOutput?
    private var wakeWordListener: WakeWordCommandListener?
    private var replyFeed: PaiSseClient?
    private var spokenReplyIds: Set<Int> = []
    private var replyBaseline = 0
    private var boundSessionID: String?

    // MARK: - The call-wide ledger and the currently-open collecting cycle

    /// The pipeline's own id for this call's take — `nil` whenever no call is active. Distinct
    /// from `boundSessionID`: this is what `VoiceRecorderController`'s durable pipeline addresses
    /// files and the ledger by, never the chat session id itself.
    private var callTakeId: String?
    /// The call's own audio, written incrementally exactly as a microphone-mode take's is — only
    /// while `collecting`, since wake-mode audio is never part of this design (see the type's own
    /// doc comment on why a dropped connection can still heal without it).
    private var callAudioFile: StreamingRecordingFile?
    private var cycleSession: VoiceRecordingSession?
    /// Every earlier cycle's own committed segments, already shifted into the call ledger's
    /// addressing — `persistCallLedger()` merges these with whichever cycle is currently open (if
    /// any) on every write, the same way `voiceSession.committedSegments` already represents a
    /// microphone-mode take's *whole* history rather than growing incrementally call to call.
    private var completedCycleSegments: [Segment] = []
    /// Every earlier cycle's own closed range, in the call ledger's addressing — what
    /// `TranscriptLedger.collecting` is built from, since `.call` mode's own gap derivation bounds
    /// itself to exactly this field.
    private var completedCollectingRanges: [SampleRange] = []
    /// Every earlier cycle's own acknowledged ranges, already shifted into the call ledger's
    /// addressing — the acknowledged counterpart to `completedCycleSegments`, merged with
    /// whichever cycle is currently open (if any) on every write exactly the same way.
    /// `persistExternalLedger`'s `acknowledged:` argument is what the durable pipeline's own gap
    /// derivation now measures against instead of word extents, so this must carry the call's
    /// whole acknowledged history, not merely the newest cycle's own.
    private var completedAcknowledgedRanges: [SampleRange] = []
    /// How many samples the call's own ledger has collected across every cycle *before* the one
    /// currently open, if any — the shift every one of that cycle's segments gets while it runs.
    /// Also what a command's own `atOffset` is built from: the ledger's own addressing, which
    /// only advances across `collecting` stretches, never across a wake-mode gap between them.
    private var callTakeCollectedSamples = 0
    private var cycleSamplesFed = 0
    /// A monotonic count of every sample this call has ever captured, in every phase — unlike
    /// `callTakeCollectedSamples`/`cycleSamplesFed`, which only advance while `collecting`. The
    /// wake-word listener's own offset is built from this and only this: `WakeWordCommandGate`
    /// debounces a repeated detection by comparing its offset against the last one accepted for
    /// that command, so an offset that stalls while `.listening` (as the ledger-addressed one
    /// does, since nothing advances it between cycles) makes a second "Kai skip" indistinguishable
    /// from the echo of the first and silently drops it forever.
    private var wakeWordCaptureOffset = 0
    /// `wakeWordCaptureOffset` as of the moment the currently-open cycle started collecting — what
    /// translates an offline detection's own `atOffset` (addressed from call entry, in
    /// `wakeWordCaptureOffset`'s own coordinates) into the call ledger's addressing: both counters
    /// advance by the same `samples.count` on every `handleCapturedChunk` call while a cycle is
    /// open, so `event.atOffset - wakeOffsetAtCycleStart` is exactly how far into the cycle the
    /// detector's own window ended, the same quantity `cycleSamplesFed` tracks.
    private var wakeOffsetAtCycleStart = 0
    private var callSampleRate = 16_000
    private var callLedgerTask: Task<Void, Never>?
    private var fallbackCommandTask: Task<Void, Never>?
    private var fallbackLastScannedSegmentCount = 0

    // MARK: - The turn's live preview, written into the bound session's own draft

    /// Whatever was already in the draft the moment this call began — the live preview below is
    /// built on top of it, and it is what the draft returns to once a turn is sent or the call
    /// ends, the same "append to whatever was already there" rule a microphone-mode take follows.
    private var preCallDraftText = ""
    /// The last preview text actually written — skips a redundant write on every poll tick where
    /// nothing has changed, matching `ComposerBar`'s own live-transcript poll.
    private var lastWrittenPreviewText: String?
    /// The whole draft as this call last wrote it — a draft that differs from it was edited by
    /// something else (typing, a send, a sync), and the preview rebuilds on top of that edit.
    private var lastWrittenDraftText: String?
    private var previewTask: Task<Void, Never>?
    /// Set synchronously, before the first `await`, for the whole of a "start"/"stop"/"send"
    /// dispatch's own cycle transition — `beginCollectingCycle()`/`endCollectingCycle()` mutate
    /// `cycleSession`/`completedCycleSegments`/`callTakeCollectedSamples` directly, none of it
    /// guarded by `CallModeStore`'s own phase, so a second command landing mid-transition (the
    /// pipeline's own `await`s run seconds, not instantly) would otherwise double-process the
    /// same segments. Dropping the whole command while this is set is deliberate: `CommandDetector`
    /// and the wake-word engine both re-arm on the next spoken command, and a duplicate this close
    /// together is far more likely an echo of the same one than Freddy actually saying it twice.
    private var isTransitioningCycle = false

    init(
        controller: VoiceRecorderController, apiClient: PaiApiClient, requestFactory: PaiRequestFactory,
        transcript: TranscriptStore, drafts: DraftStore, settingsStore: SettingsStore,
        wakeWordSettings: WakeWordSettingsStore
    ) {
        self.controller = controller
        self.apiClient = apiClient
        self.requestFactory = requestFactory
        self.transcript = transcript
        self.drafts = drafts
        self.settingsStore = settingsStore
        self.wakeWordSettings = wakeWordSettings

        // Freddy's Action Button replacement for a hardware mute: stop while recording, start
        // while listening with nothing else in flight. Registered once, for the app's whole
        // lifetime, so the intent can reach whichever call is running without this type's screen
        // ever having been on top.
        VoiceIntentBridge.shared.toggleCallMode = { [weak self] in
            guard let self, let phase = self.store?.phase, phase != .idle else { return false }
            if phase == .listening || phase == .pendingSend {
                Task { await self.handleManual(.start) }
            } else if case .collecting = phase {
                Task { await self.handleManual(.stop) }
            }
            return true
        }
        #if DEBUG
            Self.current = self
        #endif
    }

    var isActive: Bool { store != nil }
    /// The session a running call is bound to, or `nil` while none is active — what the
    /// composer's plus menu reads to tell "this session's own call" from "a call running
    /// elsewhere" (`ComposerCallMenu.state`).
    var activeSessionID: String? { boundSessionID }

    /// The last detection per command and which channel heard it — a repeat on the other channel
    /// inside the window is the same spoken command heard twice.
    private var lastDetectedCommand: [CommandKind: (at: Date, isOffline: Bool)] = [:]
    private static let detectedCommandDedupSeconds: TimeInterval = 4
    /// How long a send held on an untranscribed stretch waits before going out as it stands.
    private static let heldSendTimeout: Duration = .seconds(30)
    private var heldSendTimeoutTask: Task<Void, Never>?

    /// Entry, exit and every command run one at a time, in arrival order. Each awaits pipeline
    /// work for seconds (a final commit, a send), and two interleaving would fold one cycle twice
    /// or tear the call down under a transition still running.
    private var commandTail: Task<Void, Never>?
    private var chunkContinuation: AsyncStream<[Int16]>.Continuation?
    private var chunkConsumerTask: Task<Void, Never>?

    private func serialized<T: Sendable>(_ work: @escaping @MainActor @Sendable () async -> T) async -> T {
        let previous = commandTail
        let task = Task { @MainActor () -> T in
            await previous?.value
            return await work()
        }
        commandTail = Task { _ = await task.value }
        return await task.value
    }

    private func isApplicable(_ kind: CommandKind) -> Bool {
        guard let store else { return false }
        let hasReplyAudio: Bool
        if let speech, speech.state != .idle || speech.waitingReplyCount > 0 {
            hasReplyAudio = true
        } else {
            hasReplyAudio = false
        }
        return CallCommandApplicability.isApplicable(kind, phase: store.phase, hasReplyAudio: hasReplyAudio)
    }

    /// Whether a spoken reply may start while recording — the call screen's toggle and
    /// "Kai interrupt" both flip the same persisted setting.
    var interruptsAllowed: Bool { settingsStore.callInterruptsAllowed }

    func setInterruptsAllowed(_ allowed: Bool) {
        settingsStore.setCallInterruptsAllowed(allowed)
        AppVoiceDiagnosticsLog.shared.log(.info, "mode", "interrupts \(allowed ? "allowed" : "held while recording")")
        applyReplyHold()
    }

    /// Re-derives whether speech output is held — after every phase change and every toggle.
    private func applyReplyHold() {
        guard let store else { return }
        speech?.setHeld(
            CallInterruptPolicy.holdsReplies(interruptsAllowed: settingsStore.callInterruptsAllowed, phase: store.phase)
        )
    }

    // MARK: - Entry

    /// `false` means the call never started — the microphone was already claimed by a
    /// microphone-mode take, permission was refused, or the audio session could not be configured.
    /// The caller (the call screen's own `.task`) is expected to show that and dismiss itself.
    func enter(sessionID: String) async -> Bool {
        await serialized { [weak self] in await self?.performEnter(sessionID: sessionID) ?? false }
    }

    private func performEnter(sessionID: String) async -> Bool {
        // Reopening the call screen for the call already running (left with Back, then reached
        // again through the plus menu's "Return to Call", say) reattaches rather than
        // double-entering; a different session while one is already live is refused, the same as
        // a microphone-mode take would be — the plus menu itself routes a genuine switch through
        // `exit()` first, never through here.
        if store != nil { return boundSessionID == sessionID }
        guard controller.reserveForCallMode() else { return false }
        guard await controller.ensureMicrophonePermission() else {
            controller.releaseFromCallMode()
            return false
        }
        do {
            try controller.configureAudioSessionForCallMode()
        } catch {
            controller.releaseFromCallMode()
            return false
        }

        boundSessionID = sessionID
        preCallDraftText = drafts.draft(for: sessionID).text
        lastWrittenPreviewText = nil
        lastWrittenDraftText = nil
        let sampleRate = VoiceAudioRatePolicy.transportRate(
            hardwareRate: controller.microphoneCapture.hardwareSampleRate)
        callSampleRate = sampleRate
        callTakeCollectedSamples = 0
        wakeWordCaptureOffset = 0
        completedCycleSegments = []
        completedCollectingRanges = []
        completedAcknowledgedRanges = []
        // The exact id scheme a microphone-mode take uses — never prefixed or otherwise marked as
        // a call's — so a crashed call is reconciled at the next launch through the identical
        // path a crashed dictation already is: `RecordingReconciliation.metadata(for:)` only
        // accepts an id that parses back to a timestamp, and it is what gives a recovered call a
        // real `RecordingMeta` row (Insert, Transcribe remaining) rather than a healed ledger
        // nothing in the UI can ever point at. Collision-safe because a call and a
        // microphone-mode take can never be entered at the same instant (`reserveForCallMode()`'s
        // mutual exclusion).
        let takeId = RecordingMeta.id(forTimestampMs: Date().timeIntervalSince1970 * 1000)
        callTakeId = takeId

        // The call's own audio, written incrementally exactly as a microphone-mode take's is —
        // through `VoiceRecorderController`'s own storage, never a second one (see
        // `externalAudioStorage`'s own doc comment for why a fresh handle is not a fresh copy).
        let storage = controller.externalAudioStorage
        callAudioFile = StreamingRecordingFile(url: storage.sentURL(id: takeId), sampleRate: sampleRate)

        controller.beginExternalTake(
            TranscriptLedger(takeId: takeId, mode: .call, sampleRate: sampleRate, draftKey: sessionID, preText: "")
        ) { [weak self] in
            Task { @MainActor in
                await self?.serialized { [weak self] in
                    await self?.store?.ledgerChanged()
                    self?.drainUnsentTurnText()
                }
            }
        }

        let store = CallModeStore(
            sessionId: sessionID,
            dependencies: CallModeDependencies(
                currentLedger: { [weak self] in
                    // `@Sendable`, so a plain property read needs this assertion — the same
                    // pattern `VoiceRecorderController.init` already uses for its own dependency
                    // closures, and true for the same reason: every real caller is this
                    // `@MainActor` type's own `store`, itself only ever driven from the main actor.
                    MainActor.assumeIsolated {
                        self?.controller.currentExternalLedger
                            ?? TranscriptLedger(
                                takeId: takeId, mode: .call, sampleRate: sampleRate, draftKey: sessionID,
                                preText: "")
                    }
                },
                postMessage: { [weak self] text in
                    guard let self else { return }
                    // The same shape `ComposerBar.send` already uses: a bubble shows the instant
                    // the request goes out, named by the row it becomes once the request answers
                    // — never left to the reply feed alone, which only speaks a new assistant
                    // message and has nothing to say about Freddy's own send still in flight.
                    let sendTask = Task<PostMessageResponse, Error> {
                        try await self.apiClient.postMessage(sessionId: sessionID, message: text)
                    }
                    await MainActor.run {
                        self.transcript.trackSend(sessionId: sessionID, text: text, send: sendTask)
                    }
                    _ = try await sendTask.value
                },
                feedback: { [weak self] event in MainActor.assumeIsolated { self?.controller.handleFeedback(event) } },
                log: { level, category, message in AppVoiceDiagnosticsLog.shared.log(level, category, message) }
            ))
        self.store = store
        store.startEntering()

        setUpSpeechOutput()
        setUpWakeWordListener(sampleRate: sampleRate)
        wireCaptureIntoCallMode()

        // Attach before enabling voice processing — `SpeechOutput.attach(to:mixer:)`'s own doc
        // comment on why the order matters (an echo reference needs the playback graph connected
        // first), and `MicrophoneCapture.setVoiceProcessingEnabled`'s repeats it.
        if let speechOutput {
            controller.microphoneCapture.attachSpeechOutput(speechOutput)
        }
        try? controller.microphoneCapture.setVoiceProcessingEnabled(true)
        do {
            try controller.microphoneCapture.start(targetSampleRate: sampleRate)
        } catch {
            await teardown()
            controller.releaseFromCallMode()
            return false
        }

        await connectReplyFeed(sessionID: sessionID)
        // Opens the first cycle before the phase itself flips to `.collecting` — without this,
        // `finishEntering` set the phase but nothing ever called `beginCollectingCycle()`, so
        // every word Freddy says right after entering had nowhere to go: no session to
        // transcribe it, no audio file to capture it, and no feedback telling him so.
        await beginCollectingCycle()
        store.finishEntering(atOffset: callTakeCollectedSamples)
        applyReplyHold()
        previewTask?.cancel()
        previewTask = Task { [weak self] in await self?.streamTurnPreviewIntoDraft() }
        return true
    }

    private func setUpSpeechOutput() {
        let output = SpeechOutput()
        output.speed = Float(settingsStore.ttsSpeechRate)
        speechOutput = output

        let session = SpeechOutputSession(
            dependencies: SpeechOutputDependencies(
                mintToken: { [apiClient] purpose in try await apiClient.mintVoiceToken(purpose: purpose) },
                makeTransport: { URLSessionVoiceTtsTransport() },
                // `@Sendable`, reading a `@MainActor` store's property — same assertion as
                // `currentLedger` above, for the same reason.
                voiceId: { [settingsStore] in
                    MainActor.assumeIsolated { VoiceTtsProtocol.resolvedVoiceId(settingsStore.ttsVoiceId) }
                },
                playAudio: { [weak output] messageId, samples in
                    output?.schedule(messageId: messageId, samples: samples)
                },
                markReplyAudioComplete: { [weak output] messageId in output?.markComplete(messageId: messageId) },
                stopPlayback: { [weak output] in output?.stop() },
                feedback: { [weak self] event in MainActor.assumeIsolated { self?.controller.handleFeedback(event) } },
                log: { level, category, message in AppVoiceDiagnosticsLog.shared.log(level, category, message) }
            ))
        speech = session
        output.onFinishedPlaying = { [weak session] messageId in
            Task { @MainActor in session?.playbackFinished(messageId: messageId) }
        }
    }

    private func setUpWakeWordListener(sampleRate: Int) {
        let listener = WakeWordCommandListener()
        listener.start(
            config: wakeWordSettings.config, sampleRate: Double(sampleRate),
            feedback: { [weak self] event in self?.controller.handleFeedback(event) })
        listener.onCommand = { [weak self] event in
            Task { @MainActor in self?.routeDetectedCommand(event, isOffline: true) }
        }
        listener.isApplicable = { [weak self] kind in self?.isApplicable(kind) ?? false }
        wakeWordListener = listener
    }

    /// The shared tap's one consumer while call mode owns it — the wake-word listener always,
    /// the currently-open cycle session only while `collecting`. Never touches
    /// `controller`'s own microphone-mode wiring: that closure is overwritten here and restored
    /// (by `wireCaptureCallbacks()` running again) the next time a microphone-mode take starts,
    /// never rebuilt by this type itself.
    private func wireCaptureIntoCallMode() {
        let capture = controller.microphoneCapture
        capture.onLevel = nil
        capture.onRawChunk = nil
        capture.onConfigurationChange = { [weak self] in
            Task { @MainActor in self?.restartCaptureAfterConfigurationChange() }
        }
        // One ordered consumer, the same shape microphone mode uses: a task per chunk can resume
        // out of order across the session's own awaits.
        let (chunkStream, continuation) = AsyncStream<[Int16]>.makeStream()
        chunkContinuation = continuation
        chunkConsumerTask?.cancel()
        chunkConsumerTask = Task { [weak self] in
            for await samples in chunkStream {
                await self?.handleCapturedChunk(samples)
            }
        }
        capture.onChunk = { samples in continuation.yield(samples) }
        controller.callModeInterruptionHandler = { [weak self] began, _ in
            await self?.handleInterruption(began: began)
        }
    }

    private func restartCaptureAfterConfigurationChange() {
        guard store != nil else { return }
        controller.microphoneCapture.stop()
        speech?.setHeld(true)
        do {
            try controller.microphoneCapture.start(targetSampleRate: callSampleRate)
            releaseRepliesAfterEngineRestart()
        } catch {
            AppVoiceDiagnosticsLog.shared.log(.error, "mode", "call capture restart failed: \(error)")
            controller.handleFeedback(.captureGaveUp)
        }
    }

    /// A phone call or Siri takes the microphone; the call keeps going and takes it back when
    /// the system lets go. Tried even without `shouldResume` — a call left deaf is worse than an
    /// attempt that fails with a cue.
    private func handleInterruption(began: Bool) async {
        guard store != nil else { return }
        let capture = controller.microphoneCapture
        if began {
            capture.stop()
            speech?.setHeld(true)
            controller.handleFeedback(.interruptionPaused)
            return
        }
        do {
            try controller.configureAudioSessionForCallMode()
            try capture.start(targetSampleRate: callSampleRate)
            releaseRepliesAfterEngineRestart()
            controller.handleFeedback(.interruptionResumed)
        } catch {
            AppVoiceDiagnosticsLog.shared.log(.error, "mode", "call capture did not resume: \(error)")
            controller.handleFeedback(.captureGaveUp)
        }
    }

    /// Stopping the engine may never report the playing reply as finished, which would leave
    /// speech stuck on it — so every engine stop holds replies first, re-queueing the playing one
    /// from its start, and this lets them play again once the engine runs.
    private func releaseRepliesAfterEngineRestart() {
        speech?.setHeld(false)
        applyReplyHold()
    }

    private func handleCapturedChunk(_ samples: [Int16]) async {
        guard store != nil else { return }
        wakeWordListener?.ingest(pcm16le: samples, atOffset: wakeWordCaptureOffset)
        wakeWordCaptureOffset += samples.count

        // Gated on `cycleSession` existing, never on `store.phase == .collecting`: a cycle is
        // open (and its socket connecting) for a stretch before the store's own phase catches up
        // to it (`dispatch(.start)` awaits `beginCollectingCycle()` before calling
        // `store.handle`), and audio captured during that stretch must still reach the session —
        // otherwise it is only ever buffered by `VoiceRecordingSession`'s own preconnect buffer,
        // never handed to it at all.
        guard let session = cycleSession else { return }
        // Once `stop()` has moved the session past `.recording` — most commonly `.stopping`,
        // waiting on the final commit after "stop"/"send" — `session.ingestAudioChunk` below
        // silently drops whatever this hands it. Counting it here anyway used to inflate the
        // cycle's own `cycleSamplesFed` (and therefore the collecting range `endCollectingCycle()`
        // closes) with dead air past the point the command was actually spoken, which is exactly
        // the stretch `CommandWindowStripper` then had no hope of reaching.
        //
        // A cycle whose connection never opened is the exception: its audio is still saved and
        // counted, so it derives as a gap and is transcribed once the network is back.
        let startFailed = session.state == .idle && session.lastStartFailure != nil
        guard session.canIngestAudio || startFailed else { return }
        callAudioFile?.append(pcm16le: samples)
        let offset = cycleSamplesFed
        cycleSamplesFed += samples.count
        await session.ingestAudioChunk(pcm16le: samples, at: offset)
    }

    // MARK: - The reply feed

    private func connectReplyFeed(sessionID: String) async {
        replyBaseline = await resolveReplyBaseline(sessionID: sessionID)
        spokenReplyIds = []
        let client = PaiSseClient(
            sessionId: sessionID, requestFactory: requestFactory,
            callbacks: PaiSseClient.Callbacks(
                onInit: { [weak self] event in self?.speak(event.entries) },
                onBatch: { [weak self] event in self?.speak(event.entries) },
                onStatus: { [weak self] event in
                    self?.store?.sessionStatusChanged(event.status)
                    self?.store?.liveStatusChanged(state: event.state, blocker: event.blocker)
                },
                onActivity: {},
                onConnected: {},
                onDisconnected: {}
            ),
            initialCursor: replyBaseline)
        replyFeed = client
        client.connect()
    }

    /// The reply feed's own starting point — every message at or before this id is history,
    /// never spoken. The transcript's own window is only populated once the chat screen has
    /// actually been opened; entering a call straight from the sessions list (never having opened
    /// the transcript this launch) leaves it empty, and falling back to `0` there would have
    /// call mode speak the session's entire history out loud the moment it connects. Asking the
    /// backend directly for the newest message id is the same fallback `PaiSseClient.onInit`
    /// already relies on to catch a client back up correctly on a genuine reconnect — this only
    /// covers the one gap that isn't: getting a correct starting point before the first connect.
    ///
    /// Both sources are read and the newer wins: a loaded window can lag behind replies that
    /// arrived while its screen was not live, and speaking those again on every call entry is
    /// the same history replay from the other side.
    private func resolveReplyBaseline(sessionID: String) async -> Int {
        let loaded = transcript.window(for: sessionID).newestLoadedId ?? 0
        let tail = (try? await apiClient.getMessages(sessionId: sessionID, page: .tail(limit: 1)))?.map(\.id).max() ?? 0
        return max(loaded, tail)
    }

    private func speak(_ messages: [Message]) {
        let speakable = SpokenReplySelector.speakable(from: messages, baseline: replyBaseline, spoken: spokenReplyIds)
        for message in speakable {
            spokenReplyIds.insert(message.id)
            let blocks = MarkdownParser.parse(message.content ?? "")
            let sentences = SpeechText.sentences(of: SpeechText.speakable(blocks))
            guard !sentences.isEmpty else { continue }
            speech?.enqueue(messageId: message.id, sentences: sentences)
        }
    }

    // MARK: - Commands: offline (wake-word) and the transcript fallback

    /// Both channels converge here and on `dispatch(_:confidence:)`; `isOffline` only decides
    /// whether the offset needs translating. A command that means nothing in the current state is
    /// dropped before it can sound a confirmation tone.
    private func routeDetectedCommand(_ event: CommandEvent, isOffline: Bool) {
        guard let speech, isApplicable(event.kind) else { return }
        // Both channels may hear the same spoken command while recording — the transcript is the
        // more reliable ear for a phrase, the offline engine the faster one — so whichever lands
        // first acts and the other is dropped as the same utterance.
        // A repeat on the same channel is a real repeat — each channel already debounces itself.
        let now = Date()
        if let last = lastDetectedCommand[event.kind], last.isOffline != isOffline,
            now.timeIntervalSince(last.at) < Self.detectedCommandDedupSeconds
        {
            return
        }

        // Wall-clock is approximated at the moment this fires — neither channel has a genuine
        // take-to-wall-clock mapping the way `VoiceRecordingSession`'s own `SessionTimeline` does
        // for a single continuous socket: the offline engine scores a rolling ~2s window, and the
        // fallback only learns of a segment once ElevenLabs commits it, both already seconds
        // behind the words themselves. A small window around "now" is what `EchoWindowRejection`
        // needs and the only honest approximation available without a device to measure the real
        // lag against.
        let window = now.addingTimeInterval(-2)...now
        let phrase = CommandPhraseSet.defaults.allPhrases(for: event.kind).first ?? ""
        guard
            !EchoWindowRejection.isEcho(
                commandWindow: window, commandText: phrase, playbackWindows: speech.playbackWindows(now: now))
        else { return }
        lastDetectedCommand[event.kind] = (now, isOffline)

        // The offline engine's own `atOffset` is in `wakeWordCaptureOffset`'s addressing (from
        // call entry, advancing through wake-mode gaps a cycle never sees) — translated into the
        // call ledger's own addressing the same way `cycleSamplesFed` already is, since both
        // counters advance by the same amount on every captured chunk while a cycle is open. The
        // fallback channel's own event is already ledger-addressed (`watchFallbackCommands` builds
        // it from `CallCycleAddressing.shift`), so it needs no translation. Read before `dispatch`
        // runs — never inside it — so a "stop"/"send" is stamped where it was actually spoken,
        // not wherever `callTakeCollectedSamples` happens to land once the cycle has since closed.
        let spokenAtOffset =
            isOffline
            ? CallCycleAddressing.translateWakeWordOffset(
                event.atOffset, wakeOffsetAtCycleStart: wakeOffsetAtCycleStart,
                callTakeCollectedSamples: callTakeCollectedSamples)
            : event.atOffset
        Task {
            await serialized { [weak self] in
                await self?.dispatch(event.kind, confidence: event.confidence, spokenAtOffset: spokenAtOffset)
            }
        }
    }

    /// A background poll over the currently-open cycle's own `committedSegments` — Freddy's
    /// documented fallback, recognising every command from the ElevenLabs transcript too (the
    /// same utterance heard offline is deduplicated in `routeDetectedCommand`), only ever possible
    /// while `collecting` (the paid transcript is the only thing running then). One `CommandObservation` per newly
    /// committed segment, matching `CommandDetector`'s own contract: `isFinal: true`, word timing
    /// shifted into the call ledger's own addressing when the engine supplied it and its count
    /// agrees with the segment's own word split, `nil` otherwise — `CommandDetector`'s pause gate
    /// already degrades gracefully without it.
    private func watchFallbackCommands() async {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: Double(callSampleRate))
        fallbackLastScannedSegmentCount = 0
        while !Task.isCancelled, let session = cycleSession, session.state != .idle {
            let segments = session.committedSegments
            if segments.count > fallbackLastScannedSegmentCount {
                for segment in segments[fallbackLastScannedSegmentCount...] {
                    let base = callTakeCollectedSamples
                    let shifted = CallCycleAddressing.shift(segment, by: base)
                    // Only trusted when the engine's own word count agrees with the segment
                    // text's whitespace split — `CommandDetector`'s pause gate already falls back
                    // to the position gate alone (`nil`) whenever that is not the case, rather
                    // than trusting a misaligned mapping.
                    let rawWordCount = segment.text.split(separator: " ").count
                    let wordTimes = shifted.words?.count == rawWordCount ? shifted.words?.map(\.range) : nil
                    let observation = CommandObservation(
                        text: shifted.text, isFinal: true, wordTimes: wordTimes, atOffset: shifted.range.upperBound)
                    if let event = detector.detect(observation) {
                        routeDetectedCommand(event, isOffline: false)
                    }
                }
                fallbackLastScannedSegmentCount = segments.count
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: - Manual controls

    func handleManual(_ kind: CommandKind) async {
        await serialized { [weak self] in await self?.dispatch(kind, confidence: 1) }
    }

    /// The one place every accepted command — offline, fallback, or a manual tap — actually acts.
    /// `spokenAtOffset` is `nil` for a manual tap, which has no spoken moment to stamp: those, and
    /// `.start`/`.skip`/`.end` (never diagnosed as needing this), keep stamping at the call
    /// ledger's own current position. A "stop"/"send" heard while genuinely `.collecting` uses
    /// `spokenAtOffset` instead when one was given — where the command was actually spoken, not
    /// wherever `callTakeCollectedSamples` lands once `endCollectingCycle()` has folded in
    /// whatever this cycle captured after it, including the offline detector's own latency and
    /// the wait for the final commit. That is what lets the turn range close there too
    /// (`CallModeStore.handle(.stop)`/`.send` both close it at the event's own `atOffset`), so the
    /// command's own audio ends up outside the turn instead of merely being stripped out of it.
    private func dispatch(_ kind: CommandKind, confidence: Double, spokenAtOffset: Int? = nil) async {
        guard let store else { return }
        switch kind {
        case .start:
            guard store.phase == .listening || store.phase == .pendingSend, !isTransitioningCycle else { return }
            isTransitioningCycle = true
            await beginCollectingCycle()
            isTransitioningCycle = false
            await store.handle(CommandEvent(kind: .start, atOffset: callTakeCollectedSamples, confidence: confidence))
            applyReplyHold()
            drainUnsentTurnText()
        case .stop, .send:
            guard !isTransitioningCycle else { return }
            let previewBeforeSend = lastWrittenPreviewText ?? ""
            var stampOffset = callTakeCollectedSamples
            if case .collecting = store.phase {
                isTransitioningCycle = true
                await endCollectingCycle()
                isTransitioningCycle = false
                stampOffset = CallCycleAddressing.closingStamp(
                    spokenAtOffset: spokenAtOffset, collectedAfterCycleEnd: callTakeCollectedSamples)
            }
            await store.handle(CommandEvent(kind: kind, atOffset: stampOffset, confidence: confidence))
            applyReplyHold()
            drainUnsentTurnText()
            if store.phase == .pendingSend { armHeldSendTimeout() }
            // A send that found nothing to send must never take the words on screen with it.
            if kind == .send, store.lastSendFoundNothing, !previewBeforeSend.isEmpty {
                AppVoiceDiagnosticsLog.shared.log(
                    .warning, "mode", "send found nothing; kept \(previewBeforeSend.count) previewed chars in the draft"
                )
                appendToDraftClearingPreview("\(VoiceRecordingResult.sttPrefix)\(previewBeforeSend)")
            }
        case .skip:
            speech?.skip()
            await store.handle(
                CommandEvent(
                    kind: .skip, atOffset: spokenAtOffset ?? callTakeCollectedSamples + cycleSamplesFed,
                    confidence: confidence))
        case .interrupt:
            await store.handle(
                CommandEvent(
                    kind: .interrupt, atOffset: spokenAtOffset ?? callTakeCollectedSamples + cycleSamplesFed,
                    confidence: confidence))
            setInterruptsAllowed(!settingsStore.callInterruptsAllowed)
        case .end:
            await performExit()
        }
    }

    /// A held turn waits for its missing stretch only so long; then it goes out as it stands,
    /// and the audio stays in Past Recordings for whatever it lacked.
    private func armHeldSendTimeout() {
        heldSendTimeoutTask?.cancel()
        heldSendTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.heldSendTimeout)
            guard !Task.isCancelled else { return }
            await self?.serialized { [weak self] in
                guard let self, let store = self.store, store.phase == .pendingSend else { return }
                AppVoiceDiagnosticsLog.shared.log(.warning, "mode", "held send timed out; sending what is transcribed")
                await store.forceSend()
                self.drainUnsentTurnText()
            }
        }
    }

    private func beginCollectingCycle() async {
        cycleSamplesFed = 0
        wakeOffsetAtCycleStart = wakeWordCaptureOffset
        let session = VoiceRecordingSession(
            dependencies: VoiceRecordingDependencies(
                mintToken: { [apiClient] purpose in try await apiClient.mintVoiceToken(purpose: purpose) },
                makeRealtimeTransport: { URLSessionVoiceRealtimeTransport() },
                // Every closure below is `@Sendable`, touching this `@MainActor` type's own state
                // or `controller`'s — the same `MainActor.assumeIsolated` assertion
                // `VoiceRecorderController.init` already makes for its own identically-shaped
                // dependency closures, true here for the same reason: the only caller is this
                // session, itself only ever driven from the main actor.
                settings: { [settingsStore] in
                    MainActor.assumeIsolated { VoiceRecorderController.voiceSettings(from: settingsStore) }
                },
                feedback: { [weak self] event in MainActor.assumeIsolated { self?.controller.handleFeedback(event) } },
                health: { [weak self] in MainActor.assumeIsolated { self?.controller.connectionHealthState ?? .offline }
                },
                connectionEvent: { [weak self] event in
                    MainActor.assumeIsolated { self?.controller.reportConnectionEvent(event) }
                }
            ))
        cycleSession = session
        let sampleRate = callSampleRate
        let startTask = Task {
            // The rate capture converts to, fixed for the call — a headset joining mid-call changes
            // the hardware rate but never what this call sends.
            await session.start(hardwareSampleRate: sampleRate)
        }
        // Matches `VoiceRecorderController.start()`'s own wait: `state` leaves `.idle`
        // synchronously, before the connect's own `await` — waiting for that (never the full
        // connect, which is left running in the background below) is what lets
        // `handleCapturedChunk` start feeding this session immediately, buffered ahead of the
        // socket the same way a microphone-mode take's first chunks are, and lets the phase flip
        // to `.collecting` without Freddy's own "start" ever waiting on a mint-and-connect
        // round trip.
        var guardIterations = 0
        while session.state == .idle && guardIterations < 200 {
            await Task.yield()
            guardIterations += 1
        }
        fallbackCommandTask?.cancel()
        fallbackCommandTask = Task { [weak self] in await self?.watchFallbackCommands() }
        callLedgerTask?.cancel()
        callLedgerTask = Task { [weak self] in await self?.runCallLedgerLoop() }
        reportStartFailureIfAny(of: startTask, for: session)
    }

    /// A mint or connect failure never reaches `ConnectionHealth` the way a mid-take drop does —
    /// `VoiceRecordingDependencies.connectionEvent` only fires `.mintSucceeded`/`.socketOpened`
    /// on the way up, nothing on the way the attempt actually failed — so without this, a cycle
    /// whose very first connect never lands plays no cue and posts no notification at all:
    /// Freddy talks into a cycle that was never going to transcribe anything, with nothing
    /// telling him so. Runs detached from `beginCollectingCycle()`'s own return, on purpose — the
    /// connect itself can take seconds, and `session === cycleSession` is what keeps a failure
    /// from a cycle Freddy has already stopped from surfacing as if it were the current one's.
    private func reportStartFailureIfAny(of startTask: Task<Void, Never>, for session: VoiceRecordingSession) {
        Task { @MainActor [weak self] in
            await startTask.value
            guard let self, self.cycleSession === session, let failure = session.lastStartFailure else { return }
            self.controller.handleFeedback(.recordingStartFailed(reason: failure.userMessage))
        }
    }

    /// Writes this instant's picture of the call — every earlier cycle's own segments plus
    /// whichever cycle is currently open, if any — through `VoiceRecorderController`'s own
    /// `persistExternalLedger`, the identical write a microphone-mode take's ledger loop already
    /// gives it. An open cycle's own range is registered with no upper bound (`Int.max`):
    /// `TranscriptLedger.collectingBounds(capturedUpTo:)` clamps every entry to `capturedUpTo` on
    /// its own, so this tracks the cycle's still-growing audio without needing to be re-closed on
    /// every call — only `endCollectingCycle()` ever writes the real, closed bound, once.
    private func persistCallLedger() {
        guard let callTakeId else { return }
        var segments = completedCycleSegments
        var acknowledged = completedAcknowledgedRanges
        var capturedUpTo = callTakeCollectedSamples
        var collecting = completedCollectingRanges
        var pendingLiveRange: SampleRange?
        if let session = cycleSession {
            let base = callTakeCollectedSamples
            segments += CallCycleAddressing.shift(session.committedSegments, by: base)
            acknowledged += CallCycleAddressing.shift(session.acknowledgedRanges, by: base)
            capturedUpTo = base + max(session.capturedUpTo, cycleSamplesFed)
            collecting.append(base..<Int.max)
            pendingLiveRange = session.pendingLiveRange.map { CallCycleAddressing.shift($0, by: base) }
        }
        controller.persistExternalLedger(
            takeId: callTakeId, segments: segments, capturedUpTo: capturedUpTo, acknowledged: acknowledged,
            pendingLiveRange: pendingLiveRange, collecting: collecting)
    }

    /// Call mode's own counterpart to `VoiceRecorderController.runLedgerLoop` — one running for
    /// the whole call rather than restarted per cycle, since a wake-mode stretch between cycles
    /// has nothing for it to write; it simply idles until the next cycle opens.
    private func runCallLedgerLoop() async {
        while !Task.isCancelled, cycleSession != nil {
            persistCallLedger()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Stops the cycle's own session — which already waits for ElevenLabs' final commit before
    /// returning (`VoiceRecordingSession.stop`'s own `WaitForCommitPolicy` wait) — then folds its
    /// segments into the call's running history and writes the result, closing this cycle's own
    /// `collecting` range for good rather than leaving it open-ended.
    private func endCollectingCycle() async {
        fallbackCommandTask?.cancel()
        fallbackCommandTask = nil
        callLedgerTask?.cancel()
        callLedgerTask = nil
        guard let session = cycleSession else { return }
        await session.stop(reason: .user)

        let base = callTakeCollectedSamples
        completedCycleSegments += CallCycleAddressing.shift(session.committedSegments, by: base)
        completedAcknowledgedRanges += CallCycleAddressing.shift(session.acknowledgedRanges, by: base)
        completedCollectingRanges.append(base..<(base + cycleSamplesFed))
        callTakeCollectedSamples += cycleSamplesFed
        cycleSession = nil

        persistCallLedger()
    }

    /// Whatever `CallModeStore` most recently couldn't send — refused (a terminal session
    /// status), or thrown by `postMessage` — is folded into the draft rather than left stranded
    /// on the store's own property with nothing ever reading it. Checked from every path that can
    /// set it: right after a manual "stop"/"send" dispatch, and after the ledger-commit callback
    /// a delayed `.pendingSend` resolves through — `consumeUnsentTurnText()` is what keeps the
    /// two from ever folding the same text in twice.
    private func drainUnsentTurnText() {
        guard let store, let text = store.consumeUnsentTurnText() else { return }
        appendToDraftClearingPreview(text)
    }

    /// While a call runs, the session it is bound to sees whatever the current turn has
    /// transcribed so far — Freddy's own "see the transcript appearing in the text box" — kept
    /// current whether or not the call screen is on top, since this runs off `CallModeController`
    /// itself rather than the screen's own lifecycle. Reads `store.previewText`, which never
    /// consumes anything the way `trySend` does, so polling it changes nothing about what a later
    /// "send" actually sends.
    private func streamTurnPreviewIntoDraft() async {
        while !Task.isCancelled, let store, let sessionID = boundSessionID {
            var openRange: SampleRange?
            var openCycle = CallOpenCycleText(segments: [], partial: "")
            if case .collecting(let startOffset) = store.phase {
                openRange = startOffset..<(callTakeCollectedSamples + cycleSamplesFed)
                if let session = cycleSession {
                    let base = callTakeCollectedSamples
                    openCycle = CallOpenCycleText(
                        segments: session.committedSegments.map { CallCycleAddressing.shift($0, by: base) },
                        partial: session.partial)
                }
            }
            let ledger =
                controller.currentExternalLedger
                ?? TranscriptLedger(
                    takeId: callTakeId ?? "", mode: .call, sampleRate: callSampleRate, draftKey: sessionID,
                    preText: "")
            rebaseOnExternalDraftEdit(sessionID: sessionID)
            let preview = store.previewText(openRange: openRange, openCycle: openCycle, in: ledger)
            if preview != lastWrittenPreviewText {
                lastWrittenPreviewText = preview
                let text = VoiceRecorderController.composeLiveText(pre: preCallDraftText, partial: preview)
                lastWrittenDraftText = text
                drafts.setDraftText(key: sessionID, text: text)
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Keeps whatever else changed the draft since the preview last wrote it. An edit that leaves
    /// the preview at the end, or removes it entirely, becomes the new base; an edit inside the
    /// preview cannot be told apart from the preview itself and is overwritten.
    private func rebaseOnExternalDraftEdit(sessionID: String) {
        let current = drafts.draft(for: sessionID).text
        guard let written = lastWrittenDraftText, current != written else { return }
        let previewPart = VoiceRecorderController.composeLiveText(pre: "", partial: lastWrittenPreviewText ?? "")
        if previewPart.isEmpty || !current.contains(previewPart) {
            preCallDraftText = current
        } else if current.hasSuffix(previewPart) {
            preCallDraftText = String(current.dropLast(previewPart.count)).trimmingCharacters(in: .whitespaces)
        } else {
            return
        }
        lastWrittenPreviewText = nil
        lastWrittenDraftText = nil
    }

    /// Restores the draft to whatever it held before this call's own live preview started writing
    /// to it, then appends `text` — the shared step `drainUnsentTurnText()` and `exit()`'s own
    /// abandoned-turn handling both need: without it, the text they append lands after a preview
    /// that already shows the identical words, duplicating them. Updates `preCallDraftText` to the
    /// result, so a second append later in the same call stacks rather than overwriting the first.
    private func appendToDraftClearingPreview(_ text: String) {
        guard let sessionID = boundSessionID, !text.isEmpty else { return }
        lastWrittenPreviewText = nil
        let combined = preCallDraftText.isEmpty ? text : "\(preCallDraftText) \(text)"
        lastWrittenDraftText = combined
        drafts.setDraftText(key: sessionID, text: combined)
        preCallDraftText = combined
    }

    // MARK: - Exit

    /// Ends call mode from any of its own three doors — the "end" command, the manual End button,
    /// or a teardown after a failed entry — always through this one path, so the microphone is
    /// never left claimed and a pending turn is never silently dropped.
    func exit() async {
        await serialized { [weak self] in await self?.performExit() }
    }

    private func performExit() async {
        guard let store else { return }
        if case .collecting = store.phase {
            await endCollectingCycle()
        }
        await store.handle(CommandEvent(kind: .end, atOffset: callTakeCollectedSamples, confidence: 1))

        // Stopped before reading `lastAbandonedTurnText` below — the preview loop's own next tick
        // would otherwise race this append and either clobber it or duplicate it.
        previewTask?.cancel()
        previewTask = nil
        if let text = store.lastAbandonedTurnText {
            appendToDraftClearingPreview(text)
        }

        await teardown()
        controller.releaseFromCallMode()
        self.store = nil
    }

    /// The shared parts of ending a call, whether it ran a single second or an hour, and whether
    /// it is ending normally or because entry itself failed partway through.
    private func teardown() async {
        previewTask?.cancel()
        previewTask = nil
        replyFeed?.disconnect()
        replyFeed = nil
        fallbackCommandTask?.cancel()
        fallbackCommandTask = nil
        callLedgerTask?.cancel()
        callLedgerTask = nil
        heldSendTimeoutTask?.cancel()
        heldSendTimeoutTask = nil
        if let session = cycleSession {
            await session.stop(reason: .user)
        }
        speech?.end()
        speech = nil
        speechOutput = nil
        wakeWordListener?.stop()
        wakeWordListener = nil
        cycleSession = nil

        callAudioFile?.finalize()
        callAudioFile = nil
        // Every call that captured audio is kept and listed like any other take, transcript and
        // all — the text a call collected must survive a send that went wrong. An open gap keeps
        // healing through the backfill loop `persistExternalLedger` already scheduled, and
        // `reconcileTakes()` picks it up at the next launch if the app dies first. Only a take
        // that never captured anything is removed.
        if let callTakeId {
            if callTakeCollectedSamples > 0 {
                controller.saveExternalTake(
                    takeId: callTakeId, sampleRate: callSampleRate, capturedSamples: callTakeCollectedSamples)
            } else {
                await controller.externalAudioStorage.delete(id: callTakeId)
            }
        }
        controller.endExternalTake()
        callTakeId = nil
        completedCycleSegments = []
        completedCollectingRanges = []
        completedAcknowledgedRanges = []
        boundSessionID = nil

        let capture = controller.microphoneCapture
        capture.stop()
        capture.onChunk = nil
        chunkContinuation?.finish()
        chunkContinuation = nil
        chunkConsumerTask?.cancel()
        chunkConsumerTask = nil
        controller.callModeInterruptionHandler = nil
        capture.onRawChunk = nil
        capture.onLevel = nil
        capture.onConfigurationChange = nil
        try? capture.setVoiceProcessingEnabled(false)
        controller.restoreMicrophoneModeAudioSession()
    }
}
