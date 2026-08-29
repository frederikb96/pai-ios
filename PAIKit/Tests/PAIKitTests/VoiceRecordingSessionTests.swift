import XCTest

@testable import PAIKit

/// A scriptable stand-in for the realtime socket. `receive()` suspends until either a message is
/// pushed or the fake is told to fail — an `actor` so it is safely callable from both the test
/// (on `MainActor`) and the session's own background receive loop at once, the same concurrency
/// shape the production `URLSessionVoiceRealtimeTransport` has.
private actor FakeVoiceRealtimeTransport: VoiceRealtimeTransport {
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
    }

    func send(text: String) async throws {
        sentTexts.append(text)
    }

    func receive() async throws -> String {
        if !queuedMessages.isEmpty {
            return queuedMessages.removeFirst()
        }
        if failed {
            throw VoiceTransportError.notConnected
        }
        return try await withCheckedThrowingContinuation { continuation in
            waitingReceivers.append(continuation)
        }
    }

    func close(code: Int, reason: String?) async {
        closeCallCount += 1
        failReceivers()
    }

    /// Test control: deliver one server message to the (real) receive loop.
    func push(_ text: String) {
        if !waitingReceivers.isEmpty {
            waitingReceivers.removeFirst().resume(returning: text)
        } else {
            queuedMessages.append(text)
        }
    }

    /// Test control: simulate the connection dying mid-recording.
    func fail() {
        failed = true
        failReceivers()
    }

    private func failReceivers() {
        let receivers = waitingReceivers
        waitingReceivers = []
        for receiver in receivers { receiver.resume(throwing: VoiceTransportError.notConnected) }
    }
}

/// A controllable clock — silence detection and the post-commit wait are entirely about
/// durations, so tests advance this by hand instead of sleeping for real.
private final class TestClock: @unchecked Sendable {
    var current = Date(timeIntervalSince1970: 0)
}

@MainActor
final class VoiceRecordingSessionTests: XCTestCase {

    private let clock = TestClock()

    private func makeSession(
        transport: FakeVoiceRealtimeTransport,
        mintToken: @escaping @Sendable (VoiceTokenPurpose) async throws -> VoiceToken = { _ in
            VoiceToken(token: "tok", expiresIn: 900)
        },
        settings: VoiceSettings = VoiceSettings()
    ) -> VoiceRecordingSession {
        let dependencies = VoiceRecordingDependencies(
            mintToken: mintToken,
            makeRealtimeTransport: { transport },
            settings: { settings },
            now: { [clock] in clock.current },
            sleep: { _ in }  // instant — the post-commit wait loop must not slow tests down
        )
        return VoiceRecordingSession(dependencies: dependencies)
    }

    /// Yields until `condition` holds or the budget runs out, for asserting on state a
    /// fire-and-forget `Task { await self.stop(...) }` will eventually reach — never a fixed
    /// sleep, since everything under test here is instant (a fake transport, a no-op `sleep`),
    /// so the loop resolves in a handful of scheduler turns, not wall-clock time.
    private func waitUntil(_ condition: () -> Bool, iterations: Int = 10_000) async {
        for _ in 0..<iterations {
            if condition() { return }
            await Task.yield()
        }
    }

    /// Same as `waitUntil`, for a condition that itself needs to hop to the fake transport actor
    /// (reading `sentTexts`) rather than only touching `@MainActor` state.
    private func waitUntil(async condition: () async -> Bool, iterations: Int = 10_000) async {
        for _ in 0..<iterations {
            if await condition() { return }
            await Task.yield()
        }
    }

    // MARK: Start

    func testStartMintsAFreshTokenPerRecordingRatherThanCaching() async {
        let transport = FakeVoiceRealtimeTransport()
        actor CallCounter { var count = 0; func increment() { count += 1 } }
        let counter = CallCounter()
        let session = makeSession(
            transport: transport,
            mintToken: { _ in
                await counter.increment()
                return VoiceToken(token: "tok", expiresIn: 900)
            }
        )

        await session.start(hardwareSampleRate: 48000)
        await session.stop(reason: .user)
        await session.start(hardwareSampleRate: 48000)

        let count = await counter.count
        XCTAssertEqual(count, 2)
    }

    func test503MintFailureSurfacesAsKeyNotConfiguredAndReturnsToIdle() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(
            transport: transport,
            mintToken: { _ in throw PaiError.detail("no key", statusCode: 503) }
        )

        await session.start(hardwareSampleRate: 48000)

        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.lastStartFailure, .keyNotConfigured)
        let connectCalls1 = await transport.connectCallCount
        XCTAssertEqual(connectCalls1, 0)
    }

    func testTransportConnectFailureAlsoReturnsToIdleWithAFailure() async {
        let transport = FakeVoiceRealtimeTransport()
        await transport.setConnectError(URLError(.cannotConnectToHost))
        let session = makeSession(transport: transport)

        await session.start(hardwareSampleRate: 48000)

        XCTAssertEqual(session.state, .idle)
        XCTAssertNotNil(session.lastStartFailure)
    }

    func testSuccessfulStartEntersConnectingState() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)

        await session.start(hardwareSampleRate: 48000)

        XCTAssertEqual(session.state, .connecting)
        let connectCalls2 = await transport.connectCallCount
        XCTAssertEqual(connectCalls2, 1)
    }

    // MARK: Realtime message handling and the pre-connect buffer

    func testSessionStartedTransitionsToRecordingAndFlushesBufferedChunksInOrder() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)

        // Buffered because the state is still .connecting.
        await session.ingestAudioChunk(pcm16le: [1, 2, 3])
        await session.ingestAudioChunk(pcm16le: [4, 5, 6])
        let sentBeforeStart = await transport.sentTexts
        XCTAssertEqual(sentBeforeStart.count, 0)

        await transport.push(#"{"message_type":"session_started"}"#)
        // `state` flips to `.recording` before the buffered chunks are actually flushed (see
        // `VoiceRecordingSession.handle`'s `.sessionStarted` case), so the condition to wait on
        // is the flush's own effect, not the state transition that merely starts it.
        await waitUntil(async: { await transport.sentTexts.count == 2 })

        XCTAssertEqual(session.state, .recording)
        let sentAfterFlush = await transport.sentTexts
        XCTAssertEqual(sentAfterFlush.count, 2)
        // Order preserved: the first-buffered chunk's payload appears in the first sent frame.
        let firstPayload = RealtimeUplinkChunk.audioBase64(fromPCM16LE: [1, 2, 3])
        XCTAssertTrue(sentAfterFlush[0].contains(firstPayload))
    }

    func testChunksSentImmediatelyOnceAlreadyRecording() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        await session.ingestAudioChunk(pcm16le: [9, 9, 9])

        let sentWhileRecording = await transport.sentTexts
        XCTAssertEqual(sentWhileRecording.count, 1)
    }

    /// Regardless of what the app hands in, a muted chunk's actual payload must be silence — the
    /// real guarantee behind muting, not merely a UI flag.
    func testMutedChunksAreSentAsDigitalSilenceRegardlessOfInputSamples() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        session.toggleMute()
        await session.ingestAudioChunk(pcm16le: [Int16.max, Int16.max, Int16.max])

        let silentPayload = RealtimeUplinkChunk.audioBase64(fromPCM16LE: [0, 0, 0])
        let sent = await transport.sentTexts
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(sent[0].contains(silentPayload))
    }

    func testPartialThenCommittedTranscriptJoinIntoTranscribedText() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        await transport.push(#"{"message_type":"partial_transcript","text":"hel"}"#)
        await waitUntil { session.transcribedText == "hel" }

        await transport.push(#"{"message_type":"committed_transcript","text":"hello there"}"#)
        await transport.push(#"{"message_type":"partial_transcript","text":"how"}"#)
        await waitUntil { session.transcribedText == "hello there how" }

        XCTAssertEqual(session.transcribedText, "hello there how")
    }

    // MARK: Stop, prefixing, interruption, connection loss

    func testStopSendsACommitFrameAndTheResultIsPrefixedExactlyOnce() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }
        await transport.push(#"{"message_type":"committed_transcript","text":"hello"}"#)
        await waitUntil { session.transcribedText == "hello" }

        await session.stop(reason: .user)

        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.lastEndReason, .user)
        XCTAssertEqual(session.result.prefixedText, "stt-rec: hello")
        let sent = await transport.sentTexts
        let lastSent = try? JSONSerialization.jsonObject(with: Data(sent.last!.utf8)) as? [String: Any]
        XCTAssertEqual(lastSent?["commit"] as? Bool, true)
    }

    func testStoppingAnAlreadyIdleSessionIsANoOp() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)

        await session.stop(reason: .user)

        XCTAssertEqual(session.state, .idle)
        XCTAssertNil(session.lastEndReason)
    }

    func testInterruptionEndsTheTakeKeepingWhateverWasTranscribedSoFar() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }
        await transport.push(#"{"message_type":"partial_transcript","text":"partial words"}"#)
        await waitUntil { session.transcribedText == "partial words" }

        await session.handleInterruption()

        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.lastEndReason, .interrupted)
        XCTAssertEqual(session.transcribedText, "partial words")
    }

    func testLostConnectionDuringRecordingEndsTheTakeAsConnectionLost() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        await transport.fail()
        await waitUntil { session.state == .idle }

        XCTAssertEqual(session.lastEndReason, .connectionLost)
    }

    func testProtocolErrorMessageEndsTheTakeAsErrorAndRecordsTheMessage() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        await transport.push(#"{"message_type":"error","message":"quota exceeded"}"#)
        await waitUntil { session.state == .idle }

        XCTAssertEqual(session.lastEndReason, .error)
        XCTAssertEqual(session.lastProtocolErrorMessage, "quota exceeded")
    }

    // MARK: Silence-triggered auto-stop, end to end

    func testContinuousSilencePastGraceAndDurationAutoStopsTheRecording() async {
        let transport = FakeVoiceRealtimeTransport()
        let settings = VoiceSettings(
            silenceDetectionEnabled: true, silenceThreshold: 0.01, silenceDurationMs: 1000
        )
        let session = makeSession(transport: transport, settings: settings)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        // Default grace is 3000ms — advance past it, then feed 1000ms of continuous quiet.
        clock.current = clock.current.addingTimeInterval(3.0)
        session.ingestLevel(rms: 0.0)
        clock.current = clock.current.addingTimeInterval(1.0)
        session.ingestLevel(rms: 0.0)

        await waitUntil { session.state == .idle }

        XCTAssertEqual(session.lastEndReason, .silence)
    }

    func testLoudAudioNeverTriggersAutoStop() async {
        let transport = FakeVoiceRealtimeTransport()
        let settings = VoiceSettings(
            silenceDetectionEnabled: true, silenceThreshold: 0.01, silenceDurationMs: 1000
        )
        let session = makeSession(transport: transport, settings: settings)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        clock.current = clock.current.addingTimeInterval(10.0)
        session.ingestLevel(rms: 0.5)
        await Task.yield()

        XCTAssertEqual(session.state, .recording)
    }
}
