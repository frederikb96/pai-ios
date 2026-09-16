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
    /// Re-transcribes a stretch of audio through the batch endpoint — the backfill's word-level
    /// counterpart to `mintToken(.batch)` + `VoiceBatchTranscriber`, returning the words a
    /// `.batch` `Segment` is built from (take-relative shifting is the caller's job, since this
    /// closure only ever sees the bytes it was handed, offset zero).
    public var batchTranscribe:
        @Sendable (Data, VoiceSettings.Language) async throws -> (
            text: String, words: [Word]
        )
    public var ledgerStorage: any LedgerStorage
    public var audioReader: any TakeAudioReader
    public var feedback: @Sendable (FeedbackEvent) -> Void
    public var health: @Sendable () -> HealthState

    public init(
        mintToken: @escaping @Sendable (VoiceTokenPurpose) async throws -> VoiceToken,
        makeRealtimeTransport: @escaping @Sendable () -> VoiceRealtimeTransport,
        settings: @escaping @Sendable () -> VoiceSettings,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        batchTranscribe:
            @escaping @Sendable (Data, VoiceSettings.Language) async throws -> (
                text: String, words: [Word]
            ) = { _, _ in throw VoiceTransportError.notConnected },
        ledgerStorage: any LedgerStorage = UnconfiguredLedgerStorage(),
        audioReader: any TakeAudioReader = UnconfiguredTakeAudioReader(),
        feedback: @escaping @Sendable (FeedbackEvent) -> Void = { _ in },
        health: @escaping @Sendable () -> HealthState = { .offline }
    ) {
        self.mintToken = mintToken
        self.makeRealtimeTransport = makeRealtimeTransport
        self.settings = settings
        self.now = now
        self.sleep = sleep
        self.batchTranscribe = batchTranscribe
        self.ledgerStorage = ledgerStorage
        self.audioReader = audioReader
        self.feedback = feedback
        self.health = health
    }
}

/// A ring of the most recent ~20s of captured PCM, addressed by take offset — what a reconnect
/// bursts through the fresh socket ahead of live audio, replaying exactly what was actually
/// transmitted (mute already applied) rather than the raw capture. The renamed, repurposed
/// `PreconnectAudioBuffer`: that type's original job — everything before the very first
/// `session_started` — is unaffected and kept separately; this is the *outage* buffer, and unlike
/// the old design, it is a bounded tail rather than the store of record — the disk is that now.
private struct RecentAudioTail {
    private struct Chunk { let offset: Int; let samples: [Int16] }
    private var chunks: [Chunk] = []
    let windowSamples: Int

    init(windowSamples: Int) { self.windowSamples = max(1, windowSamples) }

    mutating func append(offset: Int, samples: [Int16]) {
        guard !samples.isEmpty else { return }
        chunks.append(Chunk(offset: offset, samples: samples))
        guard let last = chunks.last else { return }
        let cutoff = (last.offset + last.samples.count) - windowSamples
        chunks.removeAll { $0.offset + $0.samples.count <= cutoff }
    }

    /// Chunks overlapping `range`, in the order they were captured — what a burst actually
    /// replays. Never mutates the tail: the same stretch may need replaying on a second attempt.
    func chunks(in range: SampleRange) -> [(offset: Int, samples: [Int16])] {
        chunks.filter { $0.offset < range.upperBound && $0.offset + $0.samples.count > range.lowerBound }
            .map { ($0.offset, $0.samples) }
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
    /// How much of the take's most recent audio is kept in memory for an immediate re-burst after
    /// a drop, before a stretch is left for the batch backfill instead. Sent unpaced (the whole
    /// tail in a tight loop) — measured against a live connection, an unpaced burst up to 20s
    /// succeeds and completes normally; 30s and beyond gets the connection closed with
    /// `queue_overflow`. This stays at the high end of the confirmed-safe range rather than
    /// closer to 30s, since the margin is the whole point.
    static let burstTailSeconds = 20
    /// How many consecutive reconnects may re-burst the same still-uncovered stretch before it is
    /// left alone — a flapping connection would otherwise re-send the same twenty seconds forever
    /// instead of accumulating genuinely new audio.
    static let maxBurstAttempts = 2

    public private(set) var state: VoiceRecordingState = .idle
    public private(set) var isMuted = false
    /// Committed segments plus the current partial, joined and unprefixed. A caller streaming
    /// this into a composer inserts `VoiceRecordingResult.sttPrefix` once, at the moment
    /// recording starts, and keeps replacing everything after it with this — the same shape as
    /// the web's `MessageInput.tsx` live effect. The final, one-shot prefixed string is
    /// `result.prefixedText` after `stop()` returns.
    public private(set) var transcribedText = ""
    /// Every segment committed this take, in take-offset order — what a caller persists into the
    /// ledger. A gap is never stored here or anywhere in this type: it is what `TranscriptLedger
    /// .derivedGaps(capturedUpTo:)` reports once fed `committedSegments` and `capturedUpTo`, the
    /// same "derive, do not duplicate" rule the ledger itself follows.
    public private(set) var committedSegments: [Segment] = []
    /// The in-flight partial at the moment a drop caught it — shown as provisional, greyed text
    /// by a caller, and never folded into a committed segment. Cleared once a real segment covers
    /// its range.
    public private(set) var provisionalText = ""
    public private(set) var provisionalRange: SampleRange?
    /// How much of the take has been captured (handed to `ingestAudioChunk`) so far — the value a
    /// caller feeds `TranscriptLedger.derivedGaps(capturedUpTo:)` alongside `committedSegments`.
    public private(set) var capturedUpTo = 0
    public private(set) var lastEndReason: RecordingEndReason?
    /// Set only when `start()` itself failed — token mint, URL construction, transport connect.
    /// A failure mid-recording (the `.error` protocol message) is reported through
    /// `lastProtocolErrorMessage` and `state == .transcriptionStopped` instead, since by then a
    /// start failure's distinctions (key/service/permission) no longer apply.
    public private(set) var lastStartFailure: VoiceStartFailure?
    public private(set) var lastProtocolErrorMessage: String?
    /// Why the realtime socket last went away mid-take — a close reason, or the notice ElevenLabs
    /// sent before closing. The take reconnects either way; this is what a take that eventually
    /// gave up can still say about why.
    public private(set) var lastDisconnectDetail: String?

    private let dependencies: VoiceRecordingDependencies
    private var transport: VoiceRealtimeTransport?
    private var receiveTask: Task<Void, Never>?
    /// The single in-flight reconnect episode, if any — `handleConnectionLost` and
    /// `resumeAfterInterruption` both reach it, and both cancel any prior one before starting a
    /// new one so a resume racing a still-sleeping retry can never produce two.
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var preconnectBuffer = PreconnectAudioBuffer<BufferedChunk>()
    private var recentAudioTail = RecentAudioTail(windowSamples: 24000 * VoiceRecordingSession.burstTailSeconds)
    private var sessionTimeline = SessionTimeline()
    /// The stretch of the burst tail still owed a live-socket resend after a drop — cleared once
    /// a committed segment covers it, or once `maxBurstAttempts` is spent and it is left for the
    /// batch backfill instead.
    private var pendingBurstRange: SampleRange?
    private var pendingBurstAttempts = 0
    /// Set right after a reconnect's `session_started` arrives, consumed by whichever chunk `send`
    /// actually transmits next — ElevenLabs accepts `previous_text` only on a reconnect's very
    /// first chunk, so this must ride whatever goes out first, burst or live. Built from committed
    /// text ending at `coveredUpTo`, attached to audio starting at `coveredUpTo` or later — never
    /// overlapping content, which matters: `previous_text` sharing words with the audio it
    /// precedes has been observed to make ElevenLabs treat that audio as already covered and drop
    /// it from the transcript entirely, not merely provide context.
    private var pendingPreviousTextForNextChunk: String?
    /// Set alongside the moment above actually gets consumed by `send` — even unrelated
    /// `previous_text` has been observed to prefix the next committed segment with a stray
    /// `". "` artifact; `recordCommittedSegment` strips it once, on whichever commit follows.
    private var shouldStripLeadingArtifactFromNextCommit = false
    private var silenceDetector: SilenceDetector?
    /// Whether detected silence is currently withholding audio from the socket — distinct from
    /// `isMuted`, which is Freddy's own hand mute. See `ingestAudioChunk`'s own comment for why
    /// this withholds the chunk entirely rather than zeroing it the way `isMuted` does.
    private var isSilenceGated = false
    private var silenceGateStart: Date?
    /// Total time spent gated off due to silence, across every time it fired this take — the
    /// silence equivalent of `mutedMs` below.
    private var silenceGatedMs = 0
    /// The most recent withheld audio, at most `VoiceRealtimeProtocol.gatePrerollMs` of it, sent
    /// ahead of the first chunk after the gate lifts. Carries each chunk's take offset alongside
    /// its samples so the replay still lands at the right place in `SessionTimeline`.
    private var gatePreroll: [(offset: Int, samples: [Int16])] = []
    /// When a frame last reached the socket — what the keepalive measures against, so any stretch
    /// without one is covered, whether it began at a gate or a reconnect.
    private var lastUplinkAt: Date?
    private var partial = ""
    /// The furthest take offset any committed segment has covered — advances only on a real
    /// commit, never on a drop, which is exactly what leaves the uncovered stretch derivable as a
    /// gap rather than needing to be recorded twice.
    private var coveredUpTo = 0
    /// The furthest take offset actually handed to `transport.send` (or buffered toward it) —
    /// what a drop's provisional range and pending burst range are measured against.
    private var sentUpTo = 0
    private var recordingStart: Date?
    private var transportRateHz = 24000
    private var narrowband = false
    private var sttLanguage: VoiceSettings.Language = .auto
    private var mutedMs = 0
    private var lastMuteToggle: Date?
    private var awaitingFinalCommit = false
    private var isStopping = false

    /// A buffered chunk carries its take offset alongside the already-mute-resolved audio, so a
    /// chunk queued before `session_started` still lands correctly in `SessionTimeline` once it
    /// is actually flushed.
    private struct BufferedChunk: Sendable {
        let chunk: RealtimeUplinkChunk
        let offset: Int
        let sampleCount: Int
    }

    public init(dependencies: VoiceRecordingDependencies) {
        self.dependencies = dependencies
    }

    public var canStart: Bool { state == .idle }

    /// The rate negotiated for this take, fixed for its whole duration — what the app resumes
    /// capture at after a pause, so `AVAudioConverter`'s target never changes mid-take even if
    /// the hardware's own rate does (a Bluetooth headset dropping out mid-call, say).
    public var transportSampleRateHz: Int { transportRateHz }

    public var result: VoiceRecordingResult {
        // A gate still open when the take ends (the backstop firing, or an explicit stop while
        // gated) has not been folded into `silenceGatedMs` yet — same shape as `mutedMs` below.
        let gatedMs =
            silenceGatedMs
            + (silenceGateStart.map { Int(dependencies.now().timeIntervalSince($0) * 1000) } ?? 0)
        return VoiceRecordingResult(
            text: transcribedText,
            endedBy: lastEndReason ?? .user,
            durationMs: recordingStart.map { Int(dependencies.now().timeIntervalSince($0) * 1000) } ?? 0,
            mutedMs: mutedMs,
            silenceGatedMs: gatedMs,
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
        recentAudioTail = RecentAudioTail(windowSamples: transportRateHz * Self.burstTailSeconds)

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
        provisionalText = ""
        provisionalRange = nil
        capturedUpTo = 0
        coveredUpTo = 0
        sentUpTo = 0
        sessionTimeline = SessionTimeline()
        pendingBurstRange = nil
        pendingBurstAttempts = 0
        pendingPreviousTextForNextChunk = nil
        lastEndReason = nil
        lastStartFailure = nil
        lastProtocolErrorMessage = nil
        lastDisconnectDetail = nil
        mutedMs = 0
        isMuted = false
        lastMuteToggle = nil
        isSilenceGated = false
        silenceGateStart = nil
        silenceGatedMs = 0
        gatePreroll = []
        lastUplinkAt = nil
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
            let isReconnect = state == .reconnecting
            state = .recording
            reconnectAttempt = 0
            sessionTimeline.reset()
            if isReconnect {
                let committedText = assembledCommittedText()
                pendingPreviousTextForNextChunk = committedText.isEmpty ? nil : String(committedText.suffix(50))
                await burstPendingTailIfNeeded()
            }
            await flushPreconnectBuffer()

        case let .partialTranscript(text):
            partial = text
            updateTranscribedText()

        case .committedTranscript:
            // The timestamped twin (`.committedTranscriptWithWords`) is authoritative while
            // `include_timestamps=true` is always on this connection — using this message's own
            // text as well would append the same words twice. Only the acknowledgement (clearing
            // the partial, releasing the commit wait) is used.
            partial = ""
            updateTranscribedText()
            awaitingFinalCommit = false

        case let .committedTranscriptWithWords(text, words):
            if !text.isEmpty { recordCommittedSegment(text: text, words: words) }
            partial = ""
            updateTranscribedText()
            awaitingFinalCommit = false

        case let .error(message):
            lastProtocolErrorMessage = message
            await stopTranscriptionAttempts(reason: message)

        case let .sessionEnding(messageType, message):
            // The close that follows is what reconnects; this only keeps the reason, which the
            // close itself may not carry.
            lastDisconnectDetail = message.map { "\(messageType): \($0)" } ?? messageType

        case .commitThrottled, .unrecognized:
            break
        }
    }

    private func updateTranscribedText() {
        transcribedText = (committedSegments.map(\.text) + [partial]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func assembledCommittedText() -> String {
        committedSegments.map(\.text).joined(separator: " ")
    }

    /// Turns one `committed_transcript_with_timestamps` message into a take-relative `Segment`
    /// and folds it into coverage — the point where a connection-relative word timestamp becomes
    /// an address in the take, via `SessionTimeline`.
    ///
    /// A commit whose first chunk carried `previous_text` has been observed to come back with a
    /// stray leading `". "` even when the context was unrelated to the audio — stripped here,
    /// once, on whichever commit follows.
    private func recordCommittedSegment(text: String, words: [RealtimeWordTimestamp]) {
        var words = words
        var text = text
        if shouldStripLeadingArtifactFromNextCommit {
            shouldStripLeadingArtifactFromNextCommit = false
            if text.hasPrefix(". ") { text = String(text.dropFirst(2)) }
            if words.first?.text == "." { words.removeFirst() }
        }
        let takeWords: [Word] = words.compactMap { word in
            guard
                let range = sessionTimeline.takeRange(
                    startSeconds: word.start, endSeconds: word.end, sampleRate: transportRateHz
                )
            else { return nil }
            return Word(range: range, text: word.text, logprob: word.logprob)
        }
        let range: SampleRange
        if let first = takeWords.first, let last = takeWords.last {
            range = first.range.lowerBound..<last.range.upperBound
        } else {
            // No word could be placed (an empty `SessionTimeline`, in practice) — fall back to
            // whatever has been transmitted but not yet covered, rather than dropping the text.
            range = coveredUpTo..<max(coveredUpTo, sentUpTo)
        }
        guard !range.isEmpty else { return }

        let source: Segment.Source = (pendingBurstRange.map { $0.overlaps(range) } ?? false) ? .liveBurst : .live
        committedSegments.append(
            Segment(range: range, text: text, words: takeWords.isEmpty ? nil : takeWords, source: source))
        coveredUpTo = max(coveredUpTo, range.upperBound)

        if let provisional = provisionalRange, coveredUpTo >= provisional.upperBound {
            provisionalText = ""
            provisionalRange = nil
        }
        if let burst = pendingBurstRange {
            if coveredUpTo >= burst.upperBound {
                pendingBurstRange = nil
                pendingBurstAttempts = 0
            } else if coveredUpTo > burst.lowerBound {
                pendingBurstRange = coveredUpTo..<burst.upperBound
            }
        }
    }

    /// A dropped socket does not end the take by itself — over the length of recording this
    /// feature is built for, a cellular handoff, a moment of dead signal, ElevenLabs shedding load
    /// or reaching a session limit are all likely, and every one of them is survived by opening a
    /// fresh session. Reconnection has no attempt limit any more (`ReconnectPolicy`); only a fatal
    /// protocol error, which arrives as `.error` before any close, ever stops trying — and even
    /// that only stops transcription attempts, never the take (`stopTranscriptionAttempts`).
    ///
    /// The socket is deliberately left open while `.paused` (an interruption keeps the take, not
    /// the connection, alive), so it can still drop out from under a paused take — an idle
    /// realtime connection closed by the far end mid-call, say. That must never promote `.paused`
    /// to `.reconnecting` on its own: `.paused` means "the app has no microphone", and a network
    /// event finding out about that has nothing to reconnect *for* yet. So this only clears
    /// `transport`, which is the same "reconnect owed" signal `resumeAfterInterruption()` already
    /// reads for the mid-backoff-interruption case — the retry itself waits for capture to
    /// actually be running again.
    private func handleConnectionLost(closeReason: String?) async {
        guard state == .recording || state == .connecting || state == .paused || state == .reconnecting else {
            return
        }
        if let closeReason, !closeReason.isEmpty { lastDisconnectDetail = closeReason }
        if state == .recording {
            recordDropBookkeeping()
            dependencies.feedback(.connectionDropped(reason: closeReason))
        }
        transport = nil
        receiveTask?.cancel()
        receiveTask = nil
        guard state != .paused else { return }

        state = .reconnecting
        scheduleReconnectAttempt()
    }

    /// What a drop leaves behind for a caller to read as "not yet covered": the in-flight partial
    /// becomes provisional text over `[coveredUpTo, sentUpTo)`, and a pending burst range is
    /// opened (or extended) over the same window intersected with the tail — everything older
    /// than the tail is left for `derivedGaps` to surface once nothing ever commits over it.
    private func recordDropBookkeeping() {
        if !partial.isEmpty {
            provisionalText = partial
            provisionalRange = coveredUpTo..<max(coveredUpTo, sentUpTo)
        }
        partial = ""

        let tailStart = max(coveredUpTo, sentUpTo - recentAudioTail.windowSamples)
        guard tailStart < sentUpTo else { return }
        if let existing = pendingBurstRange {
            pendingBurstRange = existing.lowerBound..<max(existing.upperBound, sentUpTo)
        } else {
            pendingBurstRange = tailStart..<sentUpTo
            pendingBurstAttempts = 0
        }
    }

    /// Bursts whatever is still owed from the tail through the just-opened socket, or gives up on
    /// it once `maxBurstAttempts` is spent — the range then simply stays uncovered and is left
    /// for the batch backfill, rather than costing a third live-socket resend on every flap.
    private func burstPendingTailIfNeeded() async {
        guard let range = pendingBurstRange else { return }
        guard pendingBurstAttempts < Self.maxBurstAttempts else {
            pendingBurstRange = nil
            pendingBurstAttempts = 0
            return
        }
        pendingBurstAttempts += 1
        for entry in recentAudioTail.chunks(in: range) {
            await transmitBurst(entry.samples, offset: entry.offset)
        }
    }

    /// Replays exactly what the tail already holds (mute already resolved at original capture
    /// time) — unlike `transmit()`, never re-appends to the tail (the same stretch may need a
    /// second burst attempt) and never buffers if the socket is somehow not yet open (a burst
    /// only ever runs once `state == .recording`).
    private func transmitBurst(_ samples: [Int16], offset: Int) async {
        let chunk = RealtimeUplinkChunk(
            audioBase64: RealtimeUplinkChunk.audioBase64(fromPCM16LE: samples), commit: false,
            sampleRate: transportRateHz
        )
        await send(chunk, offset: offset, sampleCount: samples.count)
    }

    private func scheduleReconnectAttempt() {
        reconnectAttempt += 1
        let delay = ReconnectPolicy.delaySeconds(forAttempt: reconnectAttempt)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            await self?.dependencies.sleep(.seconds(delay))
            await self?.performReconnectAttempt()
        }
    }

    /// The retry itself, shared by the backoff wait above and `resumeAfterInterruption`'s
    /// no-transport fallback and `retryReconnectNow()` — all three leave `state == .reconnecting`
    /// and call straight into this, so there is exactly one place that mints the retry's token
    /// and opens its socket.
    private func performReconnectAttempt() async {
        // Torn down (stopped, or a later event already handled) while this was scheduled.
        guard state == .reconnecting else { return }
        guard dependencies.health() != .offline else {
            // The network path itself is unsatisfied — attempting a mint here would only spend a
            // round trip that cannot succeed. Wait out the same backoff and check again, rather
            // than burning an attempt count that no longer exists.
            scheduleReconnectAttempt()
            return
        }
        do {
            try await connectTransport()
        } catch {
            await handleConnectionLost(closeReason: nil)
        }
    }

    /// Called by the app once `NWPathMonitor` reports the network path satisfied again — skips
    /// whatever backoff wait is still pending so a reconnect is attempted immediately, per the
    /// design's "on path satisfied, attempt immediately" rule. A no-op when nothing is waiting.
    public func retryReconnectNow() {
        guard state == .reconnecting else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in await self?.performReconnectAttempt() }
    }

    /// A fatal protocol error (auth, quota, malformed input — anything a retry cannot fix) ends
    /// transcription attempts for the take, never the capture itself: the app keeps writing
    /// audio to disk regardless of this method, and whatever never reached ElevenLabs live is
    /// exactly what the batch backfill exists to fill in once conditions allow. Only `stop()`
    /// ever leaves `.transcriptionStopped`.
    private func stopTranscriptionAttempts(reason: String) async {
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        if let transport {
            await transport.close(code: 1000, reason: nil)
        }
        transport = nil
        if !partial.isEmpty {
            provisionalText = partial
            provisionalRange = coveredUpTo..<max(coveredUpTo, sentUpTo)
            partial = ""
        }
        dependencies.feedback(.fatalProtocolError(reason))
        state = .transcriptionStopped
    }

    // MARK: Audio ingestion — everything the app supplies

    /// Feed one RMS reading, roughly every 100-200ms, on the same clock `start()` was called
    /// with. Drives silence detection only; never sent anywhere.
    ///
    /// Fed during `.reconnecting` too: the microphone keeps capturing while the socket is
    /// replaced, so the level still describes the room. A gate that could not lift until the new
    /// session started would withhold whatever was said during the reconnect instead of buffering
    /// it for the new session.
    public func ingestLevel(rms: Double) {
        guard state == .recording || state == .connecting || state == .reconnecting,
            let recordingStart, var detector = silenceDetector
        else { return }
        let now = dependencies.now()
        let elapsedMs = Int(now.timeIntervalSince(recordingStart) * 1000)
        let action = detector.observe(rms: rms, elapsedMs: elapsedMs, muted: isMuted)
        silenceDetector = detector
        switch action {
        case .none:
            break
        case .gate:
            isSilenceGated = true
            silenceGateStart = now
        case .resume:
            if let silenceGateStart {
                silenceGatedMs += Int(now.timeIntervalSince(silenceGateStart) * 1000)
            }
            isSilenceGated = false
            silenceGateStart = nil
        case .stop:
            if let silenceGateStart {
                silenceGatedMs += Int(now.timeIntervalSince(silenceGateStart) * 1000)
            }
            isSilenceGated = false
            silenceGateStart = nil
            Task { await self.stop(reason: .silence) }
        }
    }

    /// Feed one buffer of mono PCM samples at the transport rate `start(hardwareSampleRate:)`
    /// negotiated, at `offset` — this chunk's position in the take, in samples from the take's
    /// first captured sample (`streamingSent.sampleCount` before the app's own append, in the
    /// app's own words). No resampling happens here, the app's `AVAudioConverter` already did it.
    /// `async` so the app awaits each call from its own capture-consuming task: that keeps chunks
    /// in order for free, the same guarantee `preConnectBuffer`'s `ConcurrentLinkedQueue` exists
    /// to provide on Android. Sent immediately once recording, buffered until `session_started`
    /// otherwise.
    ///
    /// Also accepted during `.transcriptionStopped`: `capturedUpTo` still advances (what a caller
    /// derives gaps against must reflect everything actually captured, not only what a live
    /// socket could use), even though nothing is transmitted — there is no transport to send to,
    /// and the app's own write to disk happens independently of this method regardless.
    ///
    /// While muted, the content actually sent is replaced with digital silence regardless of
    /// what was passed in — silence detection's `muted` guard only suppresses gating and the
    /// backstop, so this is the actual privacy guarantee, and it holds even if a bug elsewhere
    /// leaves the app's own track un-silenced.
    ///
    /// A silence gate withholds the chunk instead — the saving this feature exists for is real
    /// only if the audio does not reach ElevenLabs while it holds. Two things still go out while
    /// gated: a chunk of digital silence whenever the socket has been quiet for
    /// `VoiceRealtimeProtocol.keepaliveIntervalMs`, because ElevenLabs ends a session that hears
    /// nothing, and — once the gate lifts — the last `gatePrerollMs` of withheld audio, ahead of
    /// the chunk that lifted it. The locally saved recording is unaffected either way: it mirrors
    /// what was actually captured, not what this method decided to transmit.
    ///
    /// `.reconnecting` buffers here exactly as `.connecting` does before the first
    /// `session_started` — speech spoken during a network gap is not lost, only delayed until the
    /// retry succeeds. `.paused` is deliberately excluded: the app is not capturing during an
    /// audio interruption, so nothing should be arriving to buffer in the first place.
    public func ingestAudioChunk(pcm16le samples: [Int16], at offset: Int) async {
        guard
            state == .recording || state == .connecting || state == .reconnecting
                || state == .transcriptionStopped
        else { return }
        capturedUpTo = max(capturedUpTo, offset + samples.count)

        guard !isSilenceGated else {
            // Muted audio is silenced as it is held, not only as it is sent, so unmuting before
            // the gate lifts can never release what was captured while muted.
            holdForPreroll(isMuted ? [Int16](repeating: 0, count: samples.count) : samples, offset: offset)
            await sendKeepaliveIfDue(sampleCount: samples.count)
            return
        }
        let preroll = gatePreroll
        gatePreroll = []
        for held in preroll {
            await transmit(held.samples, offset: held.offset)
        }
        await transmit(samples, offset: offset)
    }

    private func transmit(_ samples: [Int16], offset: Int) async {
        let effectiveSamples = isMuted ? [Int16](repeating: 0, count: samples.count) : samples
        switch state {
        case .transcriptionStopped:
            // No transport to send to, and no attempt is ever made to reconnect from here — the
            // audio is already safely on disk through the app's own write, independent of this
            // method.
            return
        default:
            break
        }
        recentAudioTail.append(offset: offset, samples: effectiveSamples)
        let chunk = RealtimeUplinkChunk(
            audioBase64: RealtimeUplinkChunk.audioBase64(fromPCM16LE: effectiveSamples), commit: false,
            sampleRate: transportRateHz
        )
        if state == .recording {
            await send(chunk, offset: offset, sampleCount: samples.count)
        } else {
            preconnectBuffer.enqueue(BufferedChunk(chunk: chunk, offset: offset, sampleCount: samples.count))
        }
    }

    private func holdForPreroll(_ samples: [Int16], offset: Int) {
        gatePreroll.append((offset: offset, samples: samples))
        let limit = transportRateHz * VoiceRealtimeProtocol.gatePrerollMs / 1000
        var held = gatePreroll.reduce(0) { $0 + $1.samples.count }
        while gatePreroll.count > 1, held - gatePreroll[0].samples.count >= limit {
            held -= gatePreroll.removeFirst().samples.count
        }
    }

    /// Only while `.recording`: before `session_started` there is no session to keep alive, and
    /// a reconnect's first session gets one on the first gated chunk after it starts, since the
    /// last frame is by then long past the interval.
    private func sendKeepaliveIfDue(sampleCount: Int) async {
        guard state == .recording else { return }
        if let lastUplinkAt,
            dependencies.now().timeIntervalSince(lastUplinkAt) * 1000
                < Double(VoiceRealtimeProtocol.keepaliveIntervalMs)
        {
            return
        }
        let silence = [Int16](repeating: 0, count: sampleCount)
        let chunk = RealtimeUplinkChunk(
            audioBase64: RealtimeUplinkChunk.audioBase64(fromPCM16LE: silence), commit: false,
            sampleRate: transportRateHz
        )
        // Synthetic silence, not real captured audio — but it still occupies a real position in
        // the connection's own received-sample count, so `SessionTimeline` must know about it or
        // every later word's timestamp drifts. `capturedUpTo` is the placeholder offset: nothing
        // captured there is missing text, so a word an entry like this ever got placed at can
        // only ever land on silence.
        await send(chunk, offset: capturedUpTo, sampleCount: sampleCount)
    }

    private func flushPreconnectBuffer() async {
        for buffered in preconnectBuffer.drain() {
            await send(buffered.chunk, offset: buffered.offset, sampleCount: buffered.sampleCount)
        }
    }

    /// The one physical choke point every uplink frame passes through — where `previous_text` is
    /// injected onto whichever chunk goes out first after a reconnect, and where every
    /// successfully sent chunk with a real offset is folded into `SessionTimeline`/`sentUpTo`.
    /// `offset`/`sampleCount` are `nil`/`0` for frames with no real take position (currently:
    /// none — the commit frame and keepalive both now carry a placeholder offset deliberately,
    /// so every transmitted frame keeps the timeline aligned).
    private func send(_ chunk: RealtimeUplinkChunk, offset: Int? = nil, sampleCount: Int = 0) async {
        guard let transport else { return }
        var outgoing = chunk
        var carriesPreviousText = false
        if let previousText = pendingPreviousTextForNextChunk {
            outgoing = RealtimeUplinkChunk(
                audioBase64: chunk.audioBase64, commit: chunk.commit, sampleRate: chunk.sampleRate,
                previousText: previousText
            )
            pendingPreviousTextForNextChunk = nil
            carriesPreviousText = true
        }
        guard let data = try? outgoing.encoded() else { return }
        do {
            try await transport.send(text: String(decoding: data, as: UTF8.self))
            lastUplinkAt = dependencies.now()
            if carriesPreviousText { shouldStripLeadingArtifactFromNextCommit = true }
            if let offset, sampleCount > 0 {
                let sessionStart = sessionTimeline.nextSessionSampleStart
                sessionTimeline.recordTransmittedChunk(
                    sessionSampleStart: sessionStart, takeOffset: offset, sampleCount: sampleCount)
                sentUpTo = max(sentUpTo, offset + sampleCount)
            }
        } catch {
            // A failed send is reported by the receive loop, which sees the same dead socket.
        }
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
    /// frame or a second `finishStop`. Callable from `.transcriptionStopped` too — that state has
    /// no live transport, so the wait below and the commit frame are both skipped, and the take
    /// simply ends with whatever text the batch backfill has not yet had a chance to add.
    public func stop(reason: RecordingEndReason) async {
        guard
            state == .recording || state == .connecting || state == .paused || state == .reconnecting
                || state == .transcriptionStopped
        else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        guard !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        state = .stopping
        if transport != nil {
            awaitingFinalCommit = true
            let commitChunk = RealtimeUplinkChunk.commitFrame(sampleRate: transportRateHz)
            await send(commitChunk, offset: capturedUpTo, sampleCount: VoiceRealtimeProtocol.commitFrameSampleCount)

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
