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

private final class PlaybackSpy: @unchecked Sendable {
    private(set) var scheduledSamples: [[Float]] = []
    private(set) var stopCount = 0

    func play(_ samples: [Float]) { scheduledSamples.append(samples) }
    func stop() { stopCount += 1 }
}

private final class FeedbackRecorder: @unchecked Sendable {
    private(set) var events: [FeedbackEvent] = []
    func record(_ event: FeedbackEvent) { events.append(event) }
}

@MainActor
final class SpeechOutputSessionTests: XCTestCase {

    private let clock = TestClock()

    private func makeSession(
        transport: FakeVoiceTtsTransport,
        playback: PlaybackSpy = PlaybackSpy(),
        feedbackRecorder: FeedbackRecorder = FeedbackRecorder(),
        mintToken: @escaping @Sendable (VoiceTokenPurpose) async throws -> VoiceToken = { _ in
            VoiceToken(token: "tok", expiresIn: 900)
        }
    ) -> SpeechOutputSession {
        let dependencies = SpeechOutputDependencies(
            mintToken: mintToken,
            makeTransport: { transport },
            voiceId: { "voice-abc" },
            now: { [clock] in clock.current },
            sleep: { _ in },
            playAudio: { [playback] samples in playback.play(samples) },
            stopPlayback: { [playback] in playback.stop() },
            feedback: { [feedbackRecorder] event in feedbackRecorder.record(event) }
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

    func testEnqueueSendsInitializeContextThenEverySentenceWithFlushOnlyOnTheLast() async {
        let transport = FakeVoiceTtsTransport()
        let session = makeSession(transport: transport)

        session.enqueue(messageId: 1, sentences: ["first.", "second."])
        await waitUntil { await transport.sentTexts.count >= 3 }

        let sent = await transport.sentTexts
        XCTAssertEqual(sent.count, 3)
        XCTAssertTrue(
            sent[0].contains("\"voice_settings\""), "expected the InitializeContext frame first, got: \(sent[0])")
        XCTAssertFalse(sent[0].contains("\"flush\""))
        XCTAssertTrue(sent[1].contains("first."))
        XCTAssertFalse(sent[1].contains("\"flush\":true"))
        XCTAssertTrue(sent[2].contains("second."))
        XCTAssertTrue(sent[2].contains("\"flush\":true"))

        if case .speaking(_, let messageId) = session.state {
            XCTAssertEqual(messageId, 1)
        } else {
            XCTFail("expected .speaking, got \(session.state)")
        }
    }

    // MARK: - Audio arrives and is decoded before reaching playback

    func testAudioMessagesReachPlaybackAsDecodedFloatSamples() async {
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
        XCTAssertEqual(playback.scheduledSamples.first?.count, 3)
    }

    // MARK: - A finished context advances to the next reply

    func testContextFinishedAdvancesToTheNextQueuedReplyOnANewContext() async {
        let transport = FakeVoiceTtsTransport()
        let session = makeSession(transport: transport)

        session.enqueue(messageId: 1, sentences: ["first."])
        await waitUntil { await transport.sentTexts.count >= 2 }
        session.enqueue(messageId: 2, sentences: ["second."])

        await transport.push(#"{"isFinal":true}"#)

        await waitUntil(async: { await transport.sentTexts.contains { $0.contains("second.") } })

        if case .speaking(_, let messageId) = session.state {
            XCTAssertEqual(messageId, 2)
        } else {
            XCTFail("expected .speaking(messageId: 2), got \(session.state)")
        }
        let connectCalls = await transport.connectCallCount
        XCTAssertEqual(connectCalls, 1, "the same socket should be reused between replies")
    }

    // MARK: - Skip

    func testSkipStopsPlaybackClosesTheContextAndAdvances() async {
        let transport = FakeVoiceTtsTransport()
        let playback = PlaybackSpy()
        let session = makeSession(transport: transport, playback: playback)

        session.enqueue(messageId: 1, sentences: ["first."])
        await waitUntil { await transport.sentTexts.count >= 2 }
        session.enqueue(messageId: 2, sentences: ["second."])

        session.skip()

        XCTAssertEqual(playback.stopCount, 1)
        // Wait on the transport's own record, not on `session.state` — `state` flips to
        // `.speaking(2)` synchronously, before the frames for reply 2 are actually awaited-sent,
        // so it is not proof the send happened.
        await waitUntil(async: { await transport.sentTexts.contains { $0.contains("second.") } })

        let sent = await transport.sentTexts
        XCTAssertTrue(sent.contains { $0.contains("\"close_context\":true") })
    }

    func testSkipWithNothingElseQueuedReturnsToIdle() async {
        let transport = FakeVoiceTtsTransport()
        let session = makeSession(transport: transport)
        session.enqueue(messageId: 1, sentences: ["only one."])
        await waitUntil { await transport.sentTexts.count >= 2 }

        session.skip()

        await waitUntil { session.state == .idle }
        XCTAssertTrue(session.queue.isEmpty)
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

    func testARepeatedlyFailingReplyIsEventuallyAbandonedWithReplyNotSpoken() async {
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

        if case .speaking(_, let messageId) = session.state {
            XCTAssertEqual(messageId, 2)
        } else {
            XCTFail("expected .speaking(messageId: 2), got \(session.state)")
        }
    }

    // MARK: - Playback windows for echo rejection

    func testRecentPlaybackRecordsAWindowCoveringFirstAudioToContextFinishedWithTheRepliesFullText() async {
        let transport = FakeVoiceTtsTransport()
        let playback = PlaybackSpy()
        let session = makeSession(transport: transport, playback: playback)

        session.enqueue(messageId: 1, sentences: ["hello there.", "how are you."])
        await waitUntil { await transport.sentTexts.count >= 3 }

        let base64 = RealtimeUplinkChunk.audioBase64(fromPCM16LE: [0, 1, 2])
        await transport.push(#"{"audio":"\#(base64)"}"#)
        await waitUntil { !playback.scheduledSamples.isEmpty }
        // Audio has arrived and been scheduled, but the context has not reported finished yet —
        // nothing is finalised into `recentPlayback` until it does.
        XCTAssertTrue(session.recentPlayback.isEmpty)

        await transport.push(#"{"isFinal":true}"#)
        await waitUntil { !session.recentPlayback.isEmpty }

        let entry = try? XCTUnwrap(session.recentPlayback.first)
        XCTAssertEqual(entry?.text, "hello there. how are you.")
    }

    /// Measured against a live socket: ElevenLabs generates and delivers audio far ahead of
    /// playback, so a whole reply's PCM can arrive within a second even though it takes much
    /// longer to actually be heard. The recorded window has to reflect that longer, audible
    /// duration — not the near-instant wall-clock gap between the first chunk and `isFinal`.
    func testRecentPlaybackWindowRunsToTheAudioDurationEvenWhenEverythingArrivesInstantly() async throws {
        let transport = FakeVoiceTtsTransport()
        let playback = PlaybackSpy()
        let session = makeSession(transport: transport, playback: playback)

        session.enqueue(messageId: 1, sentences: ["a long reply."])
        await waitUntil { await transport.sentTexts.count >= 2 }

        // Exactly one second of 24kHz mono PCM, arriving and finishing (`isFinal`) with no
        // simulated wall-clock advance between the two at all.
        let oneSecondOfSamples = [Int16](repeating: 0, count: 24000)
        let base64 = RealtimeUplinkChunk.audioBase64(fromPCM16LE: oneSecondOfSamples)
        await transport.push(#"{"audio":"\#(base64)"}"#)
        await waitUntil { !playback.scheduledSamples.isEmpty }
        await transport.push(#"{"isFinal":true}"#)
        await waitUntil { !session.recentPlayback.isEmpty }

        let entry = try XCTUnwrap(session.recentPlayback.first)
        let duration = entry.window.upperBound.timeIntervalSince(entry.window.lowerBound)
        XCTAssertEqual(duration, 1.0, accuracy: 0.01)
    }

    /// Skip cuts playback short of whatever audio had already arrived — the window must be capped
    /// at when skip actually happened, not extended out to the full duration of audio ElevenLabs
    /// had already generated but that was never actually heard.
    func testSkipCapsThePlaybackWindowAtTheInterruptionRatherThanTheFullAudioDuration() async throws {
        let transport = FakeVoiceTtsTransport()
        let playback = PlaybackSpy()
        let session = makeSession(transport: transport, playback: playback)

        session.enqueue(messageId: 1, sentences: ["a very long reply."])
        await waitUntil { await transport.sentTexts.count >= 2 }

        // Ten seconds of audio arrives, but only half a second of wall clock actually passes
        // before "computer skip" cuts it off.
        let tenSecondsOfSamples = [Int16](repeating: 0, count: 240_000)
        let base64 = RealtimeUplinkChunk.audioBase64(fromPCM16LE: tenSecondsOfSamples)
        await transport.push(#"{"audio":"\#(base64)"}"#)
        await waitUntil { !playback.scheduledSamples.isEmpty }
        clock.current = clock.current.addingTimeInterval(0.5)

        session.skip()

        let entry = try XCTUnwrap(session.recentPlayback.first)
        let duration = entry.window.upperBound.timeIntervalSince(entry.window.lowerBound)
        XCTAssertEqual(duration, 0.5, accuracy: 0.01)
    }

    // MARK: - End

    func testEndClosesTheSocketAndClearsTheQueue() async {
        let transport = FakeVoiceTtsTransport()
        let session = makeSession(transport: transport)
        session.enqueue(messageId: 1, sentences: ["hi."])
        await waitUntil { await transport.connectCallCount == 1 }

        session.end()

        await waitUntil { await transport.closeCallCount == 1 }
        XCTAssertTrue(session.queue.isEmpty)
        XCTAssertEqual(session.state, .idle)
    }
}
