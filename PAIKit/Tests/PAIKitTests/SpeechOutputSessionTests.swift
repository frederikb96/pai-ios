import XCTest

@testable import PAIKit

/// A scriptable stand-in for the TTS socket — same shape as `VoiceRecordingSessionTests`'s own
/// `FakeVoiceRealtimeTransport`, since both transports share the same connect/send/receive/close
/// contract and the same reason for it: an `actor` callable safely from both the test and the
/// session's own background receive loop at once.
private actor FakeVoiceTtsTransport: VoiceTtsTransport {
    private(set) var sentTexts: [String] = []
    private(set) var connectCallCount = 0
    private(set) var closeCallCount = 0
    private var connectError: Error?

    private var queuedMessages: [String] = []
    private var waitingReceivers: [CheckedContinuation<String, Error>] = []
    private var failed = false

    func setConnectError(_ error: Error?) {
        connectError = error
    }

    func connect(url: URL) async throws {
        connectCallCount += 1
        if let connectError { throw connectError }
        failed = false
    }

    func send(text: String) async throws {
        sentTexts.append(text)
    }

    func receive() async throws -> String {
        if !queuedMessages.isEmpty {
            return queuedMessages.removeFirst()
        }
        if failed {
            throw VoiceTransportError.connectionLost(reason: nil)
        }
        return try await withCheckedThrowingContinuation { continuation in
            waitingReceivers.append(continuation)
        }
    }

    func close(code: Int, reason: String?) async {
        closeCallCount += 1
        failReceivers()
    }

    func push(_ text: String) {
        if !waitingReceivers.isEmpty {
            waitingReceivers.removeFirst().resume(returning: text)
        } else {
            queuedMessages.append(text)
        }
    }

    func fail() {
        failed = true
        failReceivers()
    }

    private func failReceivers() {
        let receivers = waitingReceivers
        waitingReceivers = []
        for receiver in receivers {
            receiver.resume(throwing: VoiceTransportError.connectionLost(reason: nil))
        }
    }
}

private final class TestClock: @unchecked Sendable {
    var current = Date(timeIntervalSince1970: 1000)
}

/// Records everything `SpeechOutputDependencies`' playback closures are asked to do — which
/// reply's samples, in what order, and which replies were told "no more audio is coming". A test
/// scripting a bursty delivery (a later reply's whole audio arriving before an earlier one is
/// confirmed heard) reads this to prove the later reply's audio was held rather than played
/// early, and prove `stopPlayback()` never silenced it.
private final class PlaybackSpy: @unchecked Sendable {
    private(set) var scheduledSamples: [(messageId: Int, samples: [Float])] = []
    private(set) var completedMessages: [Int] = []
    private(set) var stopCount = 0

    func play(_ messageId: Int, _ samples: [Float]) { scheduledSamples.append((messageId, samples)) }
    func markComplete(_ messageId: Int) { completedMessages.append(messageId) }
    func stop() { stopCount += 1 }
}

private final class FeedbackRecorder: @unchecked Sendable {
    private(set) var events: [FeedbackEvent] = []
    func record(_ event: FeedbackEvent) { events.append(event) }
}

/// Records every `dependencies.log` call — same shape as `CallModeStoreTests`' own `LogRecorder`,
/// without a real `VoiceDiagnosticsLog` or any file I/O.
private final class LogRecorder: @unchecked Sendable {
    private(set) var lines: [(level: VoiceLogLevel, category: String, message: String)] = []
    func record(_ level: VoiceLogLevel, _ category: String, _ message: String) {
        lines.append((level, category, message))
    }
}

@MainActor
final class SpeechOutputSessionTests: XCTestCase {

    private let clock = TestClock()

    private func makeSession(
        transport: FakeVoiceTtsTransport,
        playback: PlaybackSpy = PlaybackSpy(),
        feedbackRecorder: FeedbackRecorder = FeedbackRecorder(),
        logRecorder: LogRecorder? = nil,
        mintToken: @escaping @Sendable (VoiceTokenPurpose) async throws -> VoiceToken = { _ in
            VoiceToken(token: "tok", expiresIn: 900)
        },
        sleep: @escaping @Sendable (Duration) async -> Void = { _ in }
    ) -> SpeechOutputSession {
        let dependencies = SpeechOutputDependencies(
            mintToken: mintToken,
            makeTransport: { transport },
            voiceId: { "voice-abc" },
            now: { [clock] in clock.current },
            sleep: sleep,
            playAudio: { [playback] messageId, samples in playback.play(messageId, samples) },
            markReplyAudioComplete: { [playback] messageId in playback.markComplete(messageId) },
            stopPlayback: { [playback] in playback.stop() },
            feedback: { [feedbackRecorder] event in feedbackRecorder.record(event) },
            log: { level, category, message in logRecorder?.record(level, category, message) }
        )
        return SpeechOutputSession(dependencies: dependencies)
    }

    private func waitUntil(_ condition: () -> Bool, iterations: Int = 10_000) async {
        for _ in 0..<iterations {
            if condition() { return }
            await Task.yield()
        }
    }

    private func waitUntil(async condition: () async -> Bool, iterations: Int = 10_000) async {
        for _ in 0..<iterations {
            if await condition() { return }
            await Task.yield()
        }
    }

    // MARK: - Enqueue opens a context and sends every sentence

    func testEnqueueMintsAnTtsPurposeTokenConnectsAndOpensAFreshContext() async {
        let transport = FakeVoiceTtsTransport()
        actor PurposeRecorder {
            var purposes: [VoiceTokenPurpose] = []; func record(_ p: VoiceTokenPurpose) { purposes.append(p) }
        }
        let recorder = PurposeRecorder()
        let session = makeSession(
            transport: transport,
            mintToken: { purpose in
                await recorder.record(purpose)
                return VoiceToken(token: "tok", expiresIn: 900)
            })

        session.enqueue(messageId: 1, sentences: ["hello there."])
        await waitUntil { await transport.connectCallCount == 1 }

        let purposes = await recorder.purposes
        XCTAssertEqual(purposes, [.tts])
    }

    /// The closing frame is load-bearing: the service never reports a context finished until it
    /// is closed, so a reply whose last sentence is only flushed plays forever and blocks every
    /// reply queued behind it.
    func testEnqueueSendsInitializeContextThenEverySentenceWithFlushOnlyOnTheLastThenCloses() async {
        let transport = FakeVoiceTtsTransport()
        let session = makeSession(transport: transport)

        session.enqueue(messageId: 1, sentences: ["first.", "second."])
        await waitUntil { await transport.sentTexts.count >= 4 }

        let sent = await transport.sentTexts
        XCTAssertEqual(sent.count, 4)
        XCTAssertTrue(
            sent[0].contains("\"voice_settings\""), "expected the InitializeContext frame first, got: \(sent[0])")
        XCTAssertFalse(sent[0].contains("\"flush\""))
        XCTAssertTrue(sent[1].contains("first."))
        XCTAssertFalse(sent[1].contains("\"flush\":true"))
        XCTAssertTrue(sent[2].contains("second."))
        XCTAssertTrue(sent[2].contains("\"flush\":true"))
        XCTAssertTrue(sent[3].contains("\"close_context\":true"), "expected the context closed last, got: \(sent[3])")

        // No audio has arrived yet — generation and playback are decoupled, so sending every
        // sentence does not by itself mean anything is audible.
        XCTAssertEqual(session.state, .connecting)
    }

    // MARK: - Audio arrives, is decoded, and starts the reply playing

    func testTheFirstReplysFirstAudioChunkStartsItPlayingImmediately() async {
        let transport = FakeVoiceTtsTransport()
        let playback = PlaybackSpy()
        let session = makeSession(transport: transport, playback: playback)

        session.enqueue(messageId: 1, sentences: ["hi."])
        await waitUntil { await transport.sentTexts.count >= 2 }

        // No `contextId` at all — a malformed-but-still-audio frame, which the session admits
        // rather than silently dropping (see `handle(_:)`'s own guard).
        let base64 = RealtimeUplinkChunk.audioBase64(fromPCM16LE: [0, 16384, -16384])
        await transport.push(#"{"audio":"\#(base64)"}"#)

        await waitUntil { !playback.scheduledSamples.isEmpty }
        XCTAssertEqual(playback.scheduledSamples.first?.messageId, 1)
        XCTAssertEqual(playback.scheduledSamples.first?.samples.count, 3)
        XCTAssertEqual(session.state, .speaking(messageId: 1))
    }

    // MARK: - Generation pipelines ahead of playback, exactly as measured against a live socket

    /// A live socket probe showed a reply's whole audio, and its `isFinal`, arriving within about
    /// a second — long before the reply is actually finished being heard. Reply 2's generation
    /// must be free to start (and finish) the moment reply 1's generation does, without reply 2's
    /// audio being played early.
    func testAQueuedReplysGenerationStartsAssoonAsThePreviousOnesFinishesEvenWhileItIsStillPlaying() async {
        let transport = FakeVoiceTtsTransport()
        let playback = PlaybackSpy()
        let session = makeSession(transport: transport, playback: playback)

        session.enqueue(messageId: 1, sentences: ["first."])
        await waitUntil { await transport.sentTexts.count >= 2 }
        let reply1Audio = RealtimeUplinkChunk.audioBase64(fromPCM16LE: [1, 1, 1])
        await transport.push(#"{"audio":"\#(reply1Audio)"}"#)
        await waitUntil { !playback.scheduledSamples.isEmpty }  // reply 1 is now playing

        await transport.push(#"{"isFinal":true}"#)  // reply 1's generation finishes
        session.enqueue(messageId: 2, sentences: ["second."])

        await waitUntil(async: { await transport.sentTexts.contains { $0.contains("second.") } })
        let connectCalls = await transport.connectCallCount
        XCTAssertEqual(connectCalls, 1, "the same socket should be reused between replies")

        let reply2Audio = RealtimeUplinkChunk.audioBase64(fromPCM16LE: [2, 2, 2, 2, 2])
        await transport.push(#"{"audio":"\#(reply2Audio)"}"#)
        await waitUntil { session.queue.head?.messageId != 2 || session.queue.isEmpty }
        await transport.push(#"{"isFinal":true}"#)
        await waitUntil { session.queue.isEmpty }

        // Reply 2's audio fully arrived while reply 1 was still `currentlyPlayingMessageId` —
        // it must not have reached the player yet.
        XCTAssertFalse(playback.scheduledSamples.contains { $0.messageId == 2 })
        XCTAssertEqual(session.state, .speaking(messageId: 1), "reply 1 is still the one actually playing")
    }

    // MARK: - Skip interrupts exactly the reply being heard, never one still queued behind it

    /// The scenario a live socket probe surfaced directly: skip while reply 1 plays and reply 2's
    /// audio has already fully arrived. Reply 2 must still play in full once it is its turn,
    /// because its audio was held rather than handed to the player early.
    func testSkipDuringReply1WhileReply2sAudioIsAlreadyFullyDeliveredStillPlaysReply2InFull() async {
        let transport = FakeVoiceTtsTransport()
        let playback = PlaybackSpy()
        let session = makeSession(transport: transport, playback: playback)

        session.enqueue(messageId: 1, sentences: ["first."])
        await waitUntil { await transport.sentTexts.count >= 2 }
        let reply1Audio = RealtimeUplinkChunk.audioBase64(fromPCM16LE: [1, 1, 1])
        await transport.push(#"{"audio":"\#(reply1Audio)"}"#)
        await waitUntil { !playback.scheduledSamples.isEmpty }

        await transport.push(#"{"isFinal":true}"#)
        session.enqueue(messageId: 2, sentences: ["second."])
        await waitUntil(async: { await transport.sentTexts.contains { $0.contains("second.") } })

        // Reply 2's whole audio arrives and finishes generating too, all while reply 1 is still
        // the one actually playing — matching what the live socket probe measured.
        let reply2Audio = RealtimeUplinkChunk.audioBase64(fromPCM16LE: [2, 2, 2, 2, 2])
        await transport.push(#"{"audio":"\#(reply2Audio)"}"#)
        await transport.push(#"{"isFinal":true}"#)
        await waitUntil { session.queue.isEmpty }
        XCTAssertFalse(
            playback.scheduledSamples.contains { $0.messageId == 2 },
            "reply 2's audio must still be held, not already playing, before the skip")

        session.skip()

        XCTAssertEqual(playback.stopCount, 1)
        let reply2Scheduled = playback.scheduledSamples.filter { $0.messageId == 2 }
        XCTAssertEqual(
            reply2Scheduled.map(\.samples.count), [5],
            "reply 2's full, already-delivered audio must play once it is promoted")
        XCTAssertEqual(session.state, .speaking(messageId: 2))
        // Reply 1's generation had already finished (hence `[1, ...`), and reply 2 was already
        // fully generated too by the time it was promoted, so both get told there is no more
        // audio coming for them — reply 1 when its context finished, reply 2 the moment it
        // became the one playing.
        XCTAssertEqual(playback.completedMessages, [1, 2])
    }

    func testSkipBeforeAnyAudioHasArrivedCancelsTheReplyStillOnTheWire() async {
        let transport = FakeVoiceTtsTransport()
        let session = makeSession(transport: transport)
        session.enqueue(messageId: 1, sentences: ["only one."])
        await waitUntil { await transport.sentTexts.count >= 2 }

        session.skip()

        // `state` reaches `.idle` synchronously (the queue is dropped before the async
        // `closeContext` frame is even dispatched), so it is not proof that frame was sent — wait
        // on the transport's own record instead.
        await waitUntil(async: { await transport.sentTexts.contains { $0.contains("\"close_context\":true") } })
        XCTAssertTrue(session.queue.isEmpty)
        XCTAssertEqual(session.state, .idle)
    }

    func testSkipWithNothingPlayingOrGeneratingIsANoOp() {
        let transport = FakeVoiceTtsTransport()
        let playback = PlaybackSpy()
        let session = makeSession(transport: transport, playback: playback)

        session.skip()

        XCTAssertEqual(playback.stopCount, 1, "stopPlayback is harmless to call even with nothing playing")
        XCTAssertEqual(session.state, .idle)
    }

    // MARK: - A reply whose synthesis produces no audio at all never wedges playback

    func testAReplyWithNoAudioAtAllIsSkippedOverWithoutBlockingTheNextOne() async {
        let transport = FakeVoiceTtsTransport()
        let playback = PlaybackSpy()
        let session = makeSession(transport: transport, playback: playback)

        session.enqueue(messageId: 1, sentences: ["silent."])
        await waitUntil { await transport.sentTexts.count >= 2 }
        // Reply 1's context finishes without ever producing a single audio chunk.
        await transport.push(#"{"isFinal":true}"#)

        session.enqueue(messageId: 2, sentences: ["audible."])
        await waitUntil(async: { await transport.sentTexts.contains { $0.contains("audible.") } })
        let audio = RealtimeUplinkChunk.audioBase64(fromPCM16LE: [9, 9, 9])
        await transport.push(#"{"audio":"\#(audio)"}"#)

        await waitUntil { !playback.scheduledSamples.isEmpty }
        XCTAssertEqual(playback.scheduledSamples.first?.messageId, 2)
        XCTAssertEqual(session.state, .speaking(messageId: 2))
    }

    // MARK: - Playback windows are stamped from when audio was actually heard, not received

    /// Measured against a live socket: ElevenLabs can finish generating and delivering a reply's
    /// audio, and report it `isFinal`, long before that audio is actually done playing. The
    /// recorded window has to run to when the app confirms playback finished, not to when the
    /// wire said generation finished.
    func testRecentPlaybackWindowRunsToWhenPlaybackFinishedIsReportedNotToWhenAudioArrived() async throws {
        let transport = FakeVoiceTtsTransport()
        let playback = PlaybackSpy()
        let session = makeSession(transport: transport, playback: playback)

        session.enqueue(messageId: 1, sentences: ["a reply."])
        await waitUntil { await transport.sentTexts.count >= 2 }

        let audio = RealtimeUplinkChunk.audioBase64(fromPCM16LE: [1, 2, 3])
        await transport.push(#"{"audio":"\#(audio)"}"#)
        await waitUntil { !playback.scheduledSamples.isEmpty }
        let arrivalTime = clock.current

        await transport.push(#"{"isFinal":true}"#)
        await waitUntil { !playback.completedMessages.isEmpty }

        // Real playback continues well after generation finished — the whole point of the
        // measurement this fix responds to.
        clock.current = clock.current.addingTimeInterval(5)
        session.playbackFinished(messageId: 1)

        let entry = try XCTUnwrap(session.recentPlayback.first)
        XCTAssertEqual(entry.window.lowerBound, arrivalTime)
        XCTAssertEqual(entry.window.upperBound, clock.current)
        XCTAssertEqual(entry.text, "a reply.")
    }

    func testSkipsPlaybackWindowIsStampedAtTheInterruptionMomentNotAtSomeLaterOrEarlierTime() async throws {
        let transport = FakeVoiceTtsTransport()
        let playback = PlaybackSpy()
        let session = makeSession(transport: transport, playback: playback)

        session.enqueue(messageId: 1, sentences: ["a reply."])
        await waitUntil { await transport.sentTexts.count >= 2 }

        let audio = RealtimeUplinkChunk.audioBase64(fromPCM16LE: [1, 2, 3])
        await transport.push(#"{"audio":"\#(audio)"}"#)
        await waitUntil { !playback.scheduledSamples.isEmpty }
        let arrivalTime = clock.current

        clock.current = clock.current.addingTimeInterval(2)
        session.skip()

        let entry = try XCTUnwrap(session.recentPlayback.first)
        XCTAssertEqual(entry.window.lowerBound, arrivalTime)
        XCTAssertEqual(entry.window.upperBound, clock.current)
    }

    func testPlaybackFinishedIsIgnoredForAnyMessageIdOtherThanTheOneCurrentlyPlaying() async {
        let transport = FakeVoiceTtsTransport()
        let playback = PlaybackSpy()
        let session = makeSession(transport: transport, playback: playback)

        session.enqueue(messageId: 1, sentences: ["hi."])
        await waitUntil { await transport.sentTexts.count >= 2 }
        let audio = RealtimeUplinkChunk.audioBase64(fromPCM16LE: [1, 2, 3])
        await transport.push(#"{"audio":"\#(audio)"}"#)
        await waitUntil { !playback.scheduledSamples.isEmpty }

        session.playbackFinished(messageId: 999)  // some other, unrelated id

        XCTAssertTrue(session.recentPlayback.isEmpty)
        XCTAssertEqual(session.state, .speaking(messageId: 1))
    }

    // MARK: - Idle keep-alive: a quiet stretch never looks like a drop

    /// The bug this whole fix answers: ElevenLabs closes the *connection*, not just a context,
    /// after a default of 20s with nothing sent on it — far shorter than an ordinary quiet
    /// stretch of a call. Ticking repeatedly simulates a long idle stretch without an actual
    /// wait; nothing here should ever look like a drop.
    func testRepeatedIdleKeepAliveTicksPingADedicatedContextAndNeverLookLikeADrop() async {
        let transport = FakeVoiceTtsTransport()
        let recorder = FeedbackRecorder()
        let session = makeSession(transport: transport, feedbackRecorder: recorder)

        session.enqueue(messageId: 1, sentences: ["hi."])
        await waitUntil { await transport.sentTexts.count >= 2 }
        await transport.push(#"{"isFinal":true}"#)
        await waitUntil { session.queue.isEmpty }
        let sentBeforeIdle = await transport.sentTexts.count

        for _ in 0..<5 { await session.keepAliveTick() }

        let sent = await transport.sentTexts
        // One InitializeContext to open the dedicated idle context, plus one KeepContextAlive
        // frame per tick after that.
        XCTAssertEqual(sent.count, sentBeforeIdle + 1 + 5)
        XCTAssertTrue(
            sent.contains { $0.contains("\"text\":\"\"") }, "a keep-alive frame carries an empty text payload")
        XCTAssertTrue(
            recorder.events.isEmpty, "pinging the idle context alone must never look like a drop or a reconnect")
        let connectCalls = await transport.connectCallCount
        XCTAssertEqual(connectCalls, 1, "keeping the connection alive must never itself force a reconnect")
        session.end()
    }

    func testKeepAliveTickIsANoOpWhileAReplyIsStillOnTheWire() async {
        let transport = FakeVoiceTtsTransport()
        let session = makeSession(transport: transport)

        session.enqueue(messageId: 1, sentences: ["hi."])
        await waitUntil { await transport.sentTexts.count >= 2 }
        let sentBefore = await transport.sentTexts.count

        await session.keepAliveTick()

        let sentAfter = await transport.sentTexts.count
        XCTAssertEqual(
            sentAfter, sentBefore,
            "the reply's own frames already reset the connection's inactivity clock; nothing extra should be sent while it is in flight"
        )
        session.end()
    }

    func testKeepAliveTickBeforeAnyConnectionExistsIsANoOp() async {
        let transport = FakeVoiceTtsTransport()
        let session = makeSession(transport: transport)

        await session.keepAliveTick()

        let sentTexts = await transport.sentTexts
        let connectCalls = await transport.connectCallCount
        XCTAssertTrue(sentTexts.isEmpty)
        XCTAssertEqual(connectCalls, 0, "pinging must never itself open a connection")
        session.end()
    }

    // MARK: - A dropped connection is retried, resends the reply, and eventually gives up

    func testATransportFailureFiresTtsDroppedFeedback() async {
        let transport = FakeVoiceTtsTransport()
        let recorder = FeedbackRecorder()
        let session = makeSession(transport: transport, feedbackRecorder: recorder)

        session.enqueue(messageId: 1, sentences: ["hi."])
        await waitUntil { await transport.sentTexts.count >= 2 }

        await transport.fail()

        await waitUntil { recorder.events.contains(.ttsDropped) }
    }

    /// The bug this whole reconnect path exists to catch: reply 1's own two sentences (plus reply
    /// 2's one) are all handed to the transport well before any audio would normally arrive
    /// (generation runs far ahead of playback), so by the time the socket actually dies, `head
    /// .remaining` — reply 1's own — is already empty. Without resetting it, the reconnected
    /// context is never told to open at all: `advance()` returns before ever sending
    /// `initializeContext`, `contextFinished` can then never arrive, the queue never advances, and
    /// reply 2 is never spoken either, with no `replyNotSpoken` to explain why.
    func testASingleDropAfterAllSentencesSentResendsOnTheFreshContextAndTheNextReplyStillSpeaks() async {
        let transport = FakeVoiceTtsTransport()
        let recorder = FeedbackRecorder()
        let session = makeSession(transport: transport, feedbackRecorder: recorder)

        session.enqueue(messageId: 1, sentences: ["first one.", "first two."])
        session.enqueue(messageId: 2, sentences: ["second."])

        // initializeContext + two sendText frames for reply 1 alone.
        await waitUntil(async: { await transport.sentTexts.count >= 3 })
        let sentBeforeDrop = await transport.sentTexts.count

        await transport.fail()

        // A fresh connection, and — the fix — reply 1's own sentences resent on it, never left
        // stranded with nothing more to send. Counted, not merely found: "first one." already
        // appears once from the pre-drop send, so only a *second* occurrence proves a resend
        // actually happened rather than the bug's own early return leaving `sentTexts` unchanged.
        await waitUntil(async: { await transport.connectCallCount >= 2 })
        await waitUntil(async: { await transport.sentTexts.count > sentBeforeDrop })
        let textsAfterReconnect = await transport.sentTexts
        XCTAssertEqual(
            textsAfterReconnect.filter({ $0.contains("first one.") }).count, 2,
            "reply 1 must be resent on the fresh context, not left with nothing to send")

        // The reconnected context finishes normally, exactly as an ordinary one would — the queue
        // must advance, and reply 2 must still be generated, never stuck behind a reply whose
        // context was never reopened.
        await transport.push(#"{"isFinal":true}"#)
        await waitUntil(async: { await transport.sentTexts.contains { $0.contains("second.") } })
        let finalTexts = await transport.sentTexts
        XCTAssertTrue(finalTexts.contains { $0.contains("second.") })
        XCTAssertTrue(
            recorder.events.contains(.ttsReconnected), "the link coming back must be told apart from staying dropped")
    }

    /// The other half of the goal this fix answers: a reply that lands while an earlier one's
    /// reconnect is still backing off must still be spoken, not stranded behind a retry that
    /// never learns about it. The custom `sleep` closure enqueues reply 2 from *inside* the
    /// backoff wait itself, so it genuinely lands mid-reconnect rather than merely after it.
    func testAReplyEnqueuedWhileAnEarlierRepliesReconnectIsStillBackingOffIsSpokenAfterward() async {
        let transport = FakeVoiceTtsTransport()
        final class SessionBox: @unchecked Sendable { var session: SpeechOutputSession? }
        let box = SessionBox()
        let session = makeSession(
            transport: transport,
            sleep: { _ in await box.session?.enqueue(messageId: 2, sentences: ["second."]) })
        box.session = session

        session.enqueue(messageId: 1, sentences: ["first."])
        await waitUntil { await transport.sentTexts.count >= 2 }
        let sentBeforeDrop = await transport.sentTexts.count

        await transport.fail()

        // The backoff wait itself enqueued reply 2; reply 1's retry proceeds on a fresh
        // connection exactly as it would with nothing queued behind it. Waited for explicitly,
        // the same way the sibling resend test does — pushing `isFinal` any earlier would race
        // reply 1's own resend still being in flight, finishing the wrong (not-yet-opened)
        // context.
        await waitUntil(async: { await transport.connectCallCount >= 2 })
        await waitUntil(async: { await transport.sentTexts.count > sentBeforeDrop })
        await transport.push(#"{"isFinal":true}"#)

        await waitUntil(async: { await transport.sentTexts.contains { $0.contains("second.") } })
        let sent = await transport.sentTexts
        XCTAssertTrue(
            sent.contains { $0.contains("second.") },
            "a reply that lands mid-reconnect must still be sent once the queue reaches it, not lost")
    }

    func testARepeatedlyFailingReplyIsEventuallyAbandonedAndTheNextOneStillGetsGenerated() async {
        let transport = FakeVoiceTtsTransport()
        let recorder = FeedbackRecorder()
        let session = makeSession(transport: transport, feedbackRecorder: recorder)

        session.enqueue(messageId: 1, sentences: ["first."])
        session.enqueue(messageId: 2, sentences: ["second."])

        // Fail the connection on every attempt — `TtsReconnectPolicy.maxResendsPerReply` is 3,
        // so 4 straight failures must exhaust the budget and abandon the first reply. Waiting on
        // `connectCallCount > 0` alone would not force one fail per reconnect: that condition
        // stays true forever after the first connect, so every loop iteration could fire before
        // the session had even reconnected. Waiting for the count to strictly increase each time
        // is what makes each `fail()` land on a genuinely fresh connection attempt.
        var lastConnectCount = 0
        for _ in 0..<(TtsReconnectPolicy.maxResendsPerReply + 1) {
            await waitUntil(async: { await transport.connectCallCount > lastConnectCount })
            lastConnectCount = await transport.connectCallCount
            await transport.fail()
        }

        await waitUntil { recorder.events.contains(.replyNotSpoken) }
        XCTAssertTrue(recorder.events.contains(.replyNotSpoken), "the exhausted reply should have been abandoned")

        await waitUntil(async: { await transport.sentTexts.contains { $0.contains("second.") } })
    }

    // MARK: - A permanent server rejection is never retried

    /// A live probe confirmed the exact wire shape: ElevenLabs sends this JSON, then closes —
    /// never audio, and retrying only reproduces the identical rejection. `advance()` must never
    /// be scheduled again after this, unlike an ordinary drop.
    func testAServerRejectionAbandonsTheReplyWithoutAnyRetryAndFiresTtsRejected() async {
        let transport = FakeVoiceTtsTransport()
        let recorder = FeedbackRecorder()
        let session = makeSession(transport: transport, feedbackRecorder: recorder)

        session.enqueue(messageId: 1, sentences: ["hi."])
        await waitUntil(async: { await transport.connectCallCount >= 1 })
        let connectCountAtRejection = await transport.connectCallCount

        await transport.push(
            #"{"message":"A voice with voice_id abc123 does not exist.","error":"voice_id_does_not_exist","code":1008}"#
        )

        await waitUntil {
            recorder.events.contains(
                .ttsRejected(reason: "voice_id_does_not_exist", message: "A voice with voice_id abc123 does not exist.")
            )
        }
        XCTAssertTrue(recorder.events.contains(.replyNotSpoken), "the abandoned reply must still be reported")

        // Give the (nonexistent) retry machinery every chance to fire before asserting it didn't.
        for _ in 0..<50 { await Task.yield() }
        let connectCountAfterWaiting = await transport.connectCallCount
        XCTAssertEqual(connectCountAfterWaiting, connectCountAtRejection, "a rejection must never reconnect and retry")
        XCTAssertEqual(session.state, .idle)
    }

    /// Once rejected, every later reply is skipped without even attempting to connect — spending
    /// another mint-and-connect would only reproduce the identical rejection.
    func testAReplyEnqueuedAfterARejectionIsSkippedWithoutAttemptingToConnect() async {
        let transport = FakeVoiceTtsTransport()
        let recorder = FeedbackRecorder()
        let session = makeSession(transport: transport, feedbackRecorder: recorder)

        session.enqueue(messageId: 1, sentences: ["hi."])
        await waitUntil(async: { await transport.connectCallCount >= 1 })
        await transport.push(#"{"message":"bad key","error":"authentication_required","code":1008}"#)
        await waitUntil {
            recorder.events.contains(.ttsRejected(reason: "authentication_required", message: "bad key"))
        }
        let connectCountAtRejection = await transport.connectCallCount

        session.enqueue(messageId: 2, sentences: ["second."])
        for _ in 0..<50 { await Task.yield() }

        let connectCountAfterWaiting = await transport.connectCallCount
        XCTAssertEqual(connectCountAfterWaiting, connectCountAtRejection, "never attempts to connect again")
        XCTAssertEqual(
            recorder.events.filter { $0 == .replyNotSpoken }.count, 2,
            "both the abandoned first reply and the skipped second one are reported")
    }

    // MARK: - End

    func testEndClosesTheSocketAndClearsEverything() async {
        let transport = FakeVoiceTtsTransport()
        let session = makeSession(transport: transport)
        session.enqueue(messageId: 1, sentences: ["hi."])
        await waitUntil { await transport.connectCallCount == 1 }

        session.end()

        await waitUntil { await transport.closeCallCount == 1 }
        XCTAssertTrue(session.queue.isEmpty)
        XCTAssertEqual(session.state, .idle)
    }

    // MARK: - Diagnostics log

    func testConnectingLogsTheTokenMintAndTheSocketOpenAtInfo() async {
        let transport = FakeVoiceTtsTransport()
        let log = LogRecorder()
        let session = makeSession(transport: transport, logRecorder: log)

        session.enqueue(messageId: 1, sentences: ["hi."])
        await waitUntil { await transport.connectCallCount == 1 }
        await waitUntil { log.lines.contains { $0.message.contains("socket opened") } }

        let ttsLines = log.lines.filter { $0.category == "tts" }
        XCTAssertTrue(ttsLines.contains { $0.level == .info && $0.message.contains("token minted") })
        XCTAssertTrue(ttsLines.contains { $0.level == .info && $0.message.contains("socket opened") })
        session.end()
    }

    func testATransportFailureLogsAWarningNamingTheReason() async {
        let transport = FakeVoiceTtsTransport()
        let log = LogRecorder()
        let session = makeSession(transport: transport, logRecorder: log)

        session.enqueue(messageId: 1, sentences: ["hi."])
        await waitUntil { await transport.sentTexts.count >= 2 }

        await transport.fail()

        await waitUntil { log.lines.contains { $0.level == .warning } }
        let warnings = log.lines.filter { $0.category == "tts" && $0.level == .warning }
        XCTAssertTrue(warnings.contains { $0.message.contains("connection lost") })
        session.end()
    }

    func testIdleKeepAliveTicksLogAtDebugNotInfo() async {
        let transport = FakeVoiceTtsTransport()
        let log = LogRecorder()
        let session = makeSession(transport: transport, logRecorder: log)

        session.enqueue(messageId: 1, sentences: ["hi."])
        await waitUntil { await transport.sentTexts.count >= 2 }
        await transport.push(#"{"isFinal":true}"#)
        await waitUntil { session.queue.isEmpty }

        await session.keepAliveTick()

        let ttsLines = log.lines.filter { $0.category == "tts" }
        XCTAssertTrue(ttsLines.contains { $0.level == .debug && $0.message.contains("keep-alive") })
        XCTAssertFalse(
            ttsLines.contains { $0.level != .debug && $0.message.contains("keep-alive") },
            "a routine idle ping is not worth an info-level line every 60s of a call")
        session.end()
    }
}
