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
/// **The audio/transcription design, and why it is simpler than microphone mode's:** call mode's
/// own live transcription runs through a fresh `VoiceRecordingSession` per "collecting" cycle
/// (one per `start`→`stop`/`send`), not the single continuous session microphone mode uses for a
/// whole take. Each cycle addresses its own audio from zero, exactly as a microphone-mode take
/// does — never fed a non-zero starting offset, so every internal invariant that type already
/// relies on holds unchanged. Once a cycle ends, its `committedSegments` are shifted by the
/// number of samples the call's own ledger has already collected and merged in — a post-processing
/// step this type fully controls, rather than an assumption about how the session would behave if
/// handed a non-zero offset, which nothing here could verify without a device.
///
/// **What this simplifies away, deliberately:** the call-wide ledger this type builds carries no
/// `gaps` — a live-socket drop mid-cycle has no batch-backfill recovery the way a microphone-mode
/// take's does. `VoiceRecordingSession.stop()` already waits for the final commit before
/// returning (`WaitForCommitPolicy`), which covers the common case; an actual mid-cycle drop
/// would leave that cycle's text short with nothing here to heal it. Speaking a blocker the
/// session is waiting on out loud is likewise not built here — flagged elsewhere rather than
/// guessed at under time pressure.
@MainActor
@Observable
final class CallModeController {
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

    private var callLedger: TranscriptLedger?
    private var cycleSession: VoiceRecordingSession?
    /// How many samples the call's own ledger has collected across every cycle *before* the one
    /// currently open, if any — the shift every one of that cycle's segments gets once it ends.
    /// Also what a command's own `atOffset` is built from: the ledger's own addressing, which
    /// only advances across `collecting` stretches, never across a wake-mode gap between them.
    private var callTakeCollectedSamples = 0
    private var cycleSamplesFed = 0
    private var callSampleRate = 16_000
    private var fallbackCommandTask: Task<Void, Never>?
    private var fallbackLastScannedSegmentCount = 0

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
            if case .listening = phase {
                Task { await self.handleManual(.start) }
            } else if case .collecting = phase {
                Task { await self.handleManual(.stop) }
            }
            return true
        }
    }

    var isActive: Bool { store != nil }

    // MARK: - Entry

    /// `false` means the call never started — the microphone was already claimed by a
    /// microphone-mode take, permission was refused, or the audio session could not be configured.
    /// The caller (the call screen's own `.task`) is expected to show that and dismiss itself.
    func enter(sessionID: String) async -> Bool {
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
        let sampleRate = VoiceAudioRatePolicy.transportRate(
            hardwareRate: controller.microphoneCapture.hardwareSampleRate)
        callSampleRate = sampleRate
        callTakeCollectedSamples = 0
        callLedger = TranscriptLedger(
            takeId: "call-\(sessionID)-\(Int(Date().timeIntervalSince1970 * 1000))", mode: .call,
            sampleRate: sampleRate, draftKey: sessionID, preText: "")

        let store = CallModeStore(
            sessionId: sessionID,
            dependencies: CallModeDependencies(
                currentLedger: { [weak self] in
                    // `@Sendable`, so a plain property read needs this assertion — the same
                    // pattern `VoiceRecorderController.init` already uses for its own dependency
                    // closures, and true for the same reason: every real caller is this
                    // `@MainActor` type's own `store`, itself only ever driven from the main actor.
                    MainActor.assumeIsolated {
                        self?.callLedger
                            ?? TranscriptLedger(
                                takeId: "call-\(sessionID)", mode: .call, sampleRate: sampleRate,
                                draftKey: sessionID, preText: "")
                    }
                },
                postMessage: { [weak self] text in
                    guard let self else { return }
                    _ = try await self.apiClient.postMessage(sessionId: sessionID, message: text)
                },
                feedback: { [weak self] event in MainActor.assumeIsolated { self?.controller.handleFeedback(event) } }
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
            teardown()
            controller.releaseFromCallMode()
            return false
        }

        connectReplyFeed(sessionID: sessionID)
        store.finishEntering(atOffset: 0)
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
                voiceId: { [settingsStore] in MainActor.assumeIsolated { settingsStore.ttsVoiceId } },
                playAudio: { [weak output] messageId, samples in
                    output?.schedule(messageId: messageId, samples: samples)
                },
                markReplyAudioComplete: { [weak output] messageId in output?.markComplete(messageId: messageId) },
                stopPlayback: { [weak output] in output?.stop() },
                feedback: { [weak self] event in MainActor.assumeIsolated { self?.controller.handleFeedback(event) } }
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
        capture.onChunk = { [weak self] samples in
            Task { @MainActor in await self?.handleCapturedChunk(samples) }
        }
    }

    private func restartCaptureAfterConfigurationChange() {
        guard store != nil else { return }
        controller.microphoneCapture.stop()
        try? controller.microphoneCapture.start(targetSampleRate: callSampleRate)
    }

    private func handleCapturedChunk(_ samples: [Int16]) async {
        guard let store else { return }
        let wakeWordOffset = callTakeCollectedSamples + cycleSamplesFed
        wakeWordListener?.ingest(pcm16le: samples, atOffset: wakeWordOffset)

        guard case .collecting = store.phase, let session = cycleSession else { return }
        let offset = cycleSamplesFed
        cycleSamplesFed += samples.count
        await session.ingestAudioChunk(pcm16le: samples, at: offset)
    }

    // MARK: - The reply feed

    private func connectReplyFeed(sessionID: String) {
        replyBaseline = transcript.window(for: sessionID).newestLoadedId ?? 0
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

    /// `isOffline` only decides the echo/dedup bookkeeping's own labeling — both paths converge on
    /// `dispatch(_:confidence:)`. A command the offline engine already owns (per
    /// `wakeWordSettings.config.offlineCommands`) is never accepted from the fallback path, since
    /// during `collecting` both can see the same spoken words and a double-fire would send twice
    /// or skip twice.
    private func routeDetectedCommand(_ event: CommandEvent, isOffline: Bool) {
        guard let speech else { return }
        if !isOffline, wakeWordSettings.config.offlineCommands.contains(event.kind) { return }

        // Wall-clock is approximated at the moment this fires — neither channel has a genuine
        // take-to-wall-clock mapping the way `VoiceRecordingSession`'s own `SessionTimeline` does
        // for a single continuous socket: the offline engine scores a rolling ~2s window, and the
        // fallback only learns of a segment once ElevenLabs commits it, both already seconds
        // behind the words themselves. A small window around "now" is what `EchoWindowRejection`
        // needs and the only honest approximation available without a device to measure the real
        // lag against.
        let now = Date()
        let window = now.addingTimeInterval(-2)...now
        let phrase = CommandPhraseSet.defaults.allPhrases(for: event.kind).first ?? ""
        guard
            !EchoWindowRejection.isEcho(
                commandWindow: window, commandText: phrase, playbackWindows: speech.recentPlayback)
        else { return }

        Task { await dispatch(event.kind, confidence: event.confidence) }
    }

    /// A background poll over the currently-open cycle's own `committedSegments` — Freddy's
    /// documented fallback, recognising whichever commands `wakeWordSettings.config.offlineCommands`
    /// does not cover from the ElevenLabs transcript instead, only ever possible while `collecting`
    /// (the paid transcript is the only thing running then). One `CommandObservation` per newly
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
                    // Only trusted when the engine's own word count agrees with the segment
                    // text's whitespace split — `CommandDetector`'s pause gate already falls back
                    // to the position gate alone (`nil`) whenever that is not the case, rather
                    // than trusting a misaligned mapping.
                    let rawWordCount = segment.text.split(separator: " ").count
                    let shiftedWords: [SampleRange]? =
                        (segment.words?.count == rawWordCount)
                        ? segment.words?.map { (base + $0.range.lowerBound)..<(base + $0.range.upperBound) }
                        : nil
                    let observation = CommandObservation(
                        text: segment.text, isFinal: true, wordTimes: shiftedWords,
                        atOffset: base + segment.range.lowerBound)
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
        await dispatch(kind, confidence: 1)
    }

    /// The one place every accepted command — offline, fallback, or a manual tap — actually acts.
    /// `atOffset` is never taken from the caller: it is always the call ledger's own current
    /// position, since that is the only addressing `CallModeStore.turnRanges` and the ledger's
    /// own `segments` agree on. See the type's own doc comment for why.
    private func dispatch(_ kind: CommandKind, confidence: Double) async {
        guard let store else { return }
        switch kind {
        case .start:
            guard case .listening = store.phase else { return }
            await beginCollectingCycle()
            await store.handle(CommandEvent(kind: .start, atOffset: callTakeCollectedSamples, confidence: confidence))
        case .stop, .send:
            if case .collecting = store.phase {
                await endCollectingCycle()
            }
            await store.handle(CommandEvent(kind: kind, atOffset: callTakeCollectedSamples, confidence: confidence))
        case .skip:
            speech?.skip()
            await store.handle(CommandEvent(kind: .skip, atOffset: callTakeCollectedSamples, confidence: confidence))
        case .end:
            await exit()
        }
    }

    private func beginCollectingCycle() async {
        cycleSamplesFed = 0
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
        let startTask = Task {
            await session.start(hardwareSampleRate: controller.microphoneCapture.hardwareSampleRate)
        }
        // Matches `VoiceRecorderController.start()`'s own wait: `state` leaves `.idle`
        // synchronously, before the connect's own `await` — waiting for that (never the full
        // connect) is what lets `handleCapturedChunk` start feeding this session immediately,
        // buffered ahead of the socket the same way a microphone-mode take's first chunks are.
        var guardIterations = 0
        while session.state == .idle && guardIterations < 200 {
            await Task.yield()
            guardIterations += 1
        }
        await startTask.value
        fallbackCommandTask?.cancel()
        fallbackCommandTask = Task { [weak self] in await self?.watchFallbackCommands() }
    }

    /// Stops the cycle's own session — which already waits for ElevenLabs' final commit before
    /// returning (`VoiceRecordingSession.stop`'s own `WaitForCommitPolicy` wait) — then folds its
    /// segments into the call ledger, shifted into the ledger's own addressing.
    private func endCollectingCycle() async {
        fallbackCommandTask?.cancel()
        fallbackCommandTask = nil
        guard let session = cycleSession else { return }
        await session.stop(reason: .user)

        let base = callTakeCollectedSamples
        let shiftedSegments = session.committedSegments.map { segment in
            Segment(
                range: (base + segment.range.lowerBound)..<(base + segment.range.upperBound), text: segment.text,
                words: segment.words?.map {
                    Word(
                        range: (base + $0.range.lowerBound)..<(base + $0.range.upperBound), text: $0.text,
                        logprob: $0.logprob)
                }, source: segment.source)
        }
        let cycleRange = base..<(base + cycleSamplesFed)
        callTakeCollectedSamples += cycleSamplesFed
        cycleSession = nil

        guard let ledger = callLedger else { return }
        callLedger = TranscriptLedger(
            takeId: ledger.takeId, mode: .call, sampleRate: ledger.sampleRate, draftKey: ledger.draftKey,
            preText: ledger.preText, segments: ledger.segments + shiftedSegments,
            capturedUpTo: callTakeCollectedSamples, gaps: [], boundaries: ledger.boundaries,
            collecting: ledger.collecting + [cycleRange], events: ledger.events, delivered: ledger.delivered)
        await store?.ledgerChanged()
    }

    // MARK: - Exit

    /// Ends call mode from any of its own three doors — the "end" command, the manual End button,
    /// or a teardown after a failed entry — always through this one path, so the microphone is
    /// never left claimed and a pending turn is never silently dropped.
    func exit() async {
        guard let store else { return }
        if case .collecting = store.phase {
            await endCollectingCycle()
        }
        await store.handle(CommandEvent(kind: .end, atOffset: callTakeCollectedSamples, confidence: 1))

        if let text = store.lastAbandonedTurnText, !text.isEmpty, let sessionID = boundSessionID {
            let current = drafts.draft(for: sessionID).text
            drafts.setDraftText(key: sessionID, text: current.isEmpty ? text : "\(current) \(text)")
        }

        teardown()
        controller.releaseFromCallMode()
        self.store = nil
    }

    /// The shared parts of ending a call, whether it ran a single second or an hour, and whether
    /// it is ending normally or because entry itself failed partway through.
    private func teardown() {
        replyFeed?.disconnect()
        replyFeed = nil
        fallbackCommandTask?.cancel()
        fallbackCommandTask = nil
        speech?.end()
        speech = nil
        speechOutput = nil
        wakeWordListener?.stop()
        wakeWordListener = nil
        cycleSession = nil
        callLedger = nil
        boundSessionID = nil

        let capture = controller.microphoneCapture
        capture.stop()
        capture.onChunk = nil
        capture.onRawChunk = nil
        capture.onLevel = nil
        capture.onConfigurationChange = nil
        try? capture.setVoiceProcessingEnabled(false)
        controller.restoreMicrophoneModeAudioSession()
    }
}
