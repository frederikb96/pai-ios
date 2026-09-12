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
    private var failCloseReason: String?

    func setConnectError(_ error: Error?) {
        connectError = error
    }

    func connect(url: URL) async throws {
        connectCallCount += 1
        if let connectError { throw connectError }
        // A reconnect opens a genuinely new socket — matching that here is what makes `fail()`
        // representable as "this one connection dropped", not "every future one will too".
        failed = false
        failCloseReason = nil
    }

    func send(text: String) async throws {
        sentTexts.append(text)
    }

    func receive() async throws -> String {
        if !queuedMessages.isEmpty {
            return queuedMessages.removeFirst()
        }
        if failed {
            throw VoiceTransportError.connectionLost(reason: failCloseReason)
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

    /// Test control: simulate the connection dying mid-recording. `closeReason` matches what
    /// `URLSessionVoiceRealtimeTransport` would have read from a clean server-initiated close —
    /// `nil` (the default) is the far more common case of a plain network failure.
    func fail(closeReason: String? = nil) {
        failed = true
        failCloseReason = closeReason
        failReceivers()
    }

    private func failReceivers() {
        let receivers = waitingReceivers
        waitingReceivers = []
        for receiver in receivers {
            receiver.resume(throwing: VoiceTransportError.connectionLost(reason: failCloseReason))
        }
    }
}

/// A controllable clock — silence detection and the post-commit wait are entirely about
/// durations, so tests advance this by hand instead of sleeping for real.
private final class TestClock: @unchecked Sendable {
    var current = Date(timeIntervalSince1970: 0)
}

/// A `dependencies.sleep` a test can hold open — for the one scenario that genuinely needs a
/// window where reconnect's backoff has started but `connectTransport()` has not yet run (so
/// `transport` is still `nil`), which an instantly-resolving sleep can never reliably catch: the
/// reconnect Task and the test's own assertions would race with no way to know which runs first.
private actor Gate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class VoiceRecordingSessionTests: XCTestCase {

    private let clock = TestClock()

    private func makeSession(
        transport: FakeVoiceRealtimeTransport,
        mintToken: @escaping @Sendable (VoiceTokenPurpose) async throws -> VoiceToken = { _ in
            VoiceToken(token: "tok", expiresIn: 900)
        },
        settings: VoiceSettings = VoiceSettings(),
        sleep: @escaping @Sendable (Duration) async -> Void = { _ in }
    ) -> VoiceRecordingSession {
        let dependencies = VoiceRecordingDependencies(
            mintToken: mintToken,
            makeRealtimeTransport: { transport },
            settings: { settings },
            now: { [clock] in clock.current },
            sleep: sleep  // instant by default — the post-commit wait loop must not slow tests down
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

    /// A pause is not an end — the take must be resumable, not just quietly abandoned, so this
    /// is the one behaviour the old `handleInterruption` (which always ended the take) got
    /// backwards for the case that matters most: an hour in a pocket includes at least one call.
    func testInterruptionPausesRatherThanEndingTheTake() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }
        await transport.push(#"{"message_type":"partial_transcript","text":"partial words"}"#)
        await waitUntil { session.transcribedText == "partial words" }

        session.pauseForInterruption()

        XCTAssertEqual(session.state, .paused)
        XCTAssertNil(session.lastEndReason)
        XCTAssertEqual(session.transcribedText, "partial words")
    }

    /// Resuming with the socket still alive is the common case — a short interruption, connection
    /// untouched — and must not re-mint a token or touch what was already transcribed.
    func testResumingAfterAShortInterruptionContinuesTheSameTakeWithoutReconnecting() async {
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
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }
        await transport.push(#"{"message_type":"committed_transcript","text":"hello"}"#)
        await waitUntil { session.transcribedText == "hello" }

        session.pauseForInterruption()
        session.resumeAfterInterruption()

        XCTAssertEqual(session.state, .recording)
        XCTAssertEqual(session.transcribedText, "hello")
        let mintCount = await counter.count
        XCTAssertEqual(mintCount, 1, "resuming a live socket must not mint a second token")
    }

    /// Resuming while the interruption caught the take mid-reconnect (no live socket to fall
    /// back to) must not silently claim `.recording` with nowhere to send audio — it has to
    /// actually reconnect.
    func testResumingWithNoLiveTransportReconnectsInsteadOfClaimingRecording() async {
        let transport = FakeVoiceRealtimeTransport()
        let gate = Gate()
        let session = makeSession(transport: transport, sleep: { _ in await gate.wait() })
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        // The gated sleep holds the reconnect backoff open, so this catches the pause exactly
        // where it matters: `state == .reconnecting` but `connectTransport()` has not run yet —
        // `transport` is still `nil`.
        await transport.fail()
        await waitUntil { session.state == .reconnecting }
        session.pauseForInterruption()
        XCTAssertEqual(session.state, .paused)

        session.resumeAfterInterruption()
        await waitUntil { session.state == .recording }

        let connectCalls = await transport.connectCallCount
        XCTAssertEqual(connectCalls, 2, "the original connect plus exactly one reconnect")

        // Let the stale, pre-interruption reconnect task's sleep resolve too, rather than leaving
        // it dangling — its own `state == .reconnecting` guard is what makes waking up harmless.
        await gate.open()
    }

    /// The critical case a paused take used to go permanently deaf on: the socket is
    /// deliberately left open while paused, so it can still drop out from under a paused take —
    /// an idle realtime connection closed by the far end mid-call, say. That must never leave
    /// `.paused` on its own; only `resumeAfterInterruption()` may, or capture is never restarted
    /// and the app ends up claiming `.recording` with no microphone attached.
    func testConnectionLostWhilePausedStaysPausedRatherThanReconnectingOnItsOwn() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        session.pauseForInterruption()
        XCTAssertEqual(session.state, .paused)

        await transport.fail()
        // Nothing here drives a state change on its own initiative — a bounded number of yields
        // is how "this never happens" is provable, rather than "has not happened yet".
        for _ in 0..<200 { await Task.yield() }
        XCTAssertEqual(session.state, .paused, "a network event alone must never leave .paused")

        session.resumeAfterInterruption()
        await waitUntil { session.state == .reconnecting }
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        let connectCalls = await transport.connectCallCount
        XCTAssertEqual(connectCalls, 2, "the original connect plus exactly one reconnect kicked off by resuming")
    }

    func testStoppingWhilePausedEndsTheTakeAsUserRatherThanBeingIgnored() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }
        session.pauseForInterruption()

        await session.stop(reason: .user)

        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.lastEndReason, .user)
    }

    // MARK: Reconnect

    /// The scenario the block leader's report calls out by name: a connection drop with no close
    /// reason at all, the shape of a cellular handoff rather than a documented ElevenLabs close —
    /// must reconnect rather than ending the take the way a plain network blip used to.
    func testConnectionLostWithNoCloseReasonReconnectsRatherThanEndingTheTake() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        await transport.fail()
        await waitUntil { session.state == .reconnecting }
        XCTAssertNil(session.lastEndReason, "must not have ended the take")

        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        let connectCalls = await transport.connectCallCount
        XCTAssertEqual(connectCalls, 2)
    }

    /// Audio spoken while the connection was down is not lost — it queues the same way
    /// pre-`session_started` audio always has, and reaches the new connection once it flushes.
    func testAudioCapturedDuringAReconnectIsBufferedAndFlushedOnceReconnected() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        await transport.fail()
        await waitUntil { session.state == .reconnecting }
        await session.ingestAudioChunk(pcm16le: [7, 7, 7])
        let sentWhileDown = await transport.sentTexts
        XCTAssertEqual(sentWhileDown.count, 0)

        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil(async: { await transport.sentTexts.count == 1 })

        let payload = RealtimeUplinkChunk.audioBase64(fromPCM16LE: [7, 7, 7])
        let sent = await transport.sentTexts
        XCTAssertTrue(sent[0].contains(payload))
    }

    /// A server close that carries a reason is still a close the take survives — ElevenLabs
    /// closes healthy sessions for load, time limits and inactivity, and ending the take on any
    /// reason but one is what turned every silence gate into a lost recording.
    func testServerCloseWithAReasonReconnectsAndKeepsTheReason() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        await transport.fail(closeReason: "normal closure")
        await waitUntil { session.state == .reconnecting }
        XCTAssertNil(session.lastEndReason, "must not have ended the take")
        XCTAssertEqual(session.lastDisconnectDetail, "normal closure")

        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }
        let connectCalls = await transport.connectCallCount
        XCTAssertEqual(connectCalls, 2)
    }

    /// The notice ElevenLabs sends before closing an idle or overloaded session must not end the
    /// take itself — the close after it reconnects — but it is the only record of why.
    func testSessionEndingNoticeKeepsTheTakeAndItsReasonUntilTheCloseReconnects() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        await transport.push(#"{"message_type":"insufficient_audio_activity","message":"no audio"}"#)
        await waitUntil { session.lastDisconnectDetail != nil }
        XCTAssertEqual(session.state, .recording)
        XCTAssertEqual(session.lastDisconnectDetail, "insufficient_audio_activity: no audio")

        await transport.fail()
        await waitUntil { session.state == .reconnecting }
        XCTAssertNil(session.lastEndReason)
        XCTAssertEqual(session.lastDisconnectDetail, "insufficient_audio_activity: no audio")
    }

    /// A failure a retry cannot fix ends the take straight away rather than spending five
    /// reconnects on a token or quota that will be refused every time.
    func testQuotaExceededEndsTheTakeAsErrorWithoutReconnecting() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        await transport.push(#"{"message_type":"quota_exceeded","message":"out of credits"}"#)
        await waitUntil { session.state == .idle }

        XCTAssertEqual(session.lastEndReason, .error)
        XCTAssertEqual(session.lastProtocolErrorMessage, "quota_exceeded: out of credits")
        let connectCalls = await transport.connectCallCount
        XCTAssertEqual(connectCalls, 1)
    }

    /// `ReconnectPolicy.maxAttempts` is 5 — exhausting it must give up rather than retrying
    /// forever, the same ceiling the ported Android policy already enforces.
    func testReconnectGivesUpAfterMaxAttemptsRatherThanRetryingForever() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        // Every reconnect attempt from here on fails to connect at all, so the retry loop must
        // exhaust `ReconnectPolicy.maxAttempts` on its own rather than looping forever.
        await transport.setConnectError(URLError(.cannotConnectToHost))
        await transport.fail()
        await waitUntil({ session.state == .idle }, iterations: 100_000)

        XCTAssertEqual(session.lastEndReason, .connectionLost)
        let connectCalls = await transport.connectCallCount
        // The original connect, plus one attempt per `ReconnectPolicy.maxAttempts`.
        XCTAssertEqual(connectCalls, 1 + ReconnectPolicy.maxAttempts)
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

    // MARK: Silence gating, end to end

    /// The regression this guards: silence used to auto-stop the take outright. It must now gate
    /// the audio off — the take stays `.recording` and nothing new reaches the transport — rather
    /// than ending it.
    func testContinuousSilencePastGraceAndDurationGatesTheAudioWithoutEndingTheTake() async {
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
        await Task.yield()

        XCTAssertEqual(session.state, .recording)
        XCTAssertNil(session.lastEndReason)

        // Gated: the chunk's audio must not reach ElevenLabs. Nothing has been sent yet this
        // take, so the one frame that does go out is a keepalive of the same length, all silence.
        await session.ingestAudioChunk(pcm16le: [Int16.max, Int16.max, Int16.max])
        let sentWhileGated = await transport.sentTexts
        XCTAssertEqual(sentWhileGated.count, 1)
        XCTAssertTrue(sentWhileGated[0].contains(RealtimeUplinkChunk.audioBase64(fromPCM16LE: [0, 0, 0])))
    }

    /// The failure this guards: a gate that sends nothing is an idle session, and ElevenLabs
    /// closes an idle session — so every pause past the silence duration ended the take. A gate
    /// must send silence often enough to keep the session, and no more often than that.
    func testAGateKeepsTheSessionAliveWithSilenceAtTheKeepaliveInterval() async {
        let transport = FakeVoiceRealtimeTransport()
        let settings = VoiceSettings(
            silenceDetectionEnabled: true, silenceThreshold: 0.01, silenceDurationMs: 1000
        )
        let session = makeSession(transport: transport, settings: settings)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        clock.current = clock.current.addingTimeInterval(3.0)
        session.ingestLevel(rms: 0.0)
        await session.ingestAudioChunk(pcm16le: [5, 5, 5])
        clock.current = clock.current.addingTimeInterval(1.0)
        session.ingestLevel(rms: 0.0)  // gates, one second after the last real frame

        let interval = TimeInterval(VoiceRealtimeProtocol.keepaliveIntervalMs) / 1000
        clock.current = clock.current.addingTimeInterval(interval - 1.5)
        await session.ingestAudioChunk(pcm16le: [9, 9, 9])
        let beforeInterval = await transport.sentTexts
        XCTAssertEqual(beforeInterval.count, 1, "only the real frame before the gate")

        clock.current = clock.current.addingTimeInterval(0.5)
        await session.ingestAudioChunk(pcm16le: [9, 9, 9])
        let atInterval = await transport.sentTexts
        XCTAssertEqual(atInterval.count, 2)
        XCTAssertTrue((atInterval.last ?? "").contains(RealtimeUplinkChunk.audioBase64(fromPCM16LE: [0, 0, 0])))

        clock.current = clock.current.addingTimeInterval(interval - 0.1)
        await session.ingestAudioChunk(pcm16le: [9, 9, 9])
        let sent = await transport.sentTexts
        XCTAssertEqual(sent.count, 2, "the next keepalive is measured from the last one")
        XCTAssertEqual(session.state, .recording)
    }

    /// Lifting the gate replays only the most recent `gatePrerollMs` of withheld audio, oldest
    /// first, ahead of the chunk that lifted it — never the whole pause.
    func testLiftingTheGateReplaysOnlyTheLastMomentOfWithheldAudioInOrder() async {
        let transport = FakeVoiceRealtimeTransport()
        let settings = VoiceSettings(
            silenceDetectionEnabled: true, silenceThreshold: 0.01, silenceDurationMs: 1000
        )
        let session = makeSession(transport: transport, settings: settings)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        clock.current = clock.current.addingTimeInterval(3.0)
        session.ingestLevel(rms: 0.0)
        await session.ingestAudioChunk(pcm16le: [1])
        clock.current = clock.current.addingTimeInterval(1.0)
        session.ingestLevel(rms: 0.0)

        // 100ms chunks at 24kHz, each marked by its value; the preroll holds 300ms of them.
        let chunkSamples = 2400
        for marker in Int16(10)...Int16(14) {
            await session.ingestAudioChunk(pcm16le: [Int16](repeating: marker, count: chunkSamples))
        }
        let sentBeforeResume = await transport.sentTexts.count

        session.ingestLevel(rms: 0.5)
        await session.ingestAudioChunk(pcm16le: [Int16](repeating: 20, count: chunkSamples))

        let sent = await transport.sentTexts
        let replayed = Array(sent.dropFirst(sentBeforeResume))
        let expected: [Int16] = [12, 13, 14, 20]
        XCTAssertEqual(replayed.count, expected.count)
        for (frame, marker) in zip(replayed, expected) {
            let payload = RealtimeUplinkChunk.audioBase64(
                fromPCM16LE: [Int16](repeating: marker, count: chunkSamples)
            )
            XCTAssertTrue(frame.contains(payload), "expected the \(marker) chunk here")
        }
    }

    /// Speech that starts while a gated take is reconnecting must lift the gate there and then,
    /// and reach the new session once it starts — not wait out the reconnect behind a gate.
    func testSpeechDuringAReconnectLiftsTheGateAndReachesTheNewSession() async {
        let transport = FakeVoiceRealtimeTransport()
        let settings = VoiceSettings(
            silenceDetectionEnabled: true, silenceThreshold: 0.01, silenceDurationMs: 1000
        )
        let session = makeSession(transport: transport, settings: settings)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        clock.current = clock.current.addingTimeInterval(3.0)
        session.ingestLevel(rms: 0.0)
        clock.current = clock.current.addingTimeInterval(1.0)
        session.ingestLevel(rms: 0.0)

        await transport.fail(closeReason: "insufficient_audio_activity")
        await waitUntil { session.state == .reconnecting }
        session.ingestLevel(rms: 0.5)
        await session.ingestAudioChunk(pcm16le: [8, 8, 8])

        await transport.push(#"{"message_type":"session_started"}"#)
        let speech = RealtimeUplinkChunk.audioBase64(fromPCM16LE: [8, 8, 8])
        await waitUntil(async: { await transport.sentTexts.contains { $0.contains(speech) } })
        let sent = await transport.sentTexts
        XCTAssertTrue(sent.contains { $0.contains(speech) })
        XCTAssertEqual(session.state, .recording)
    }

    /// Audio held while muted must stay silent when the gate lifts after an unmute — the replay
    /// must never become a way to release what was captured under mute.
    func testAudioHeldWhileMutedIsReplayedAsSilenceEvenAfterUnmuting() async {
        let transport = FakeVoiceRealtimeTransport()
        let settings = VoiceSettings(
            silenceDetectionEnabled: true, silenceThreshold: 0.01, silenceDurationMs: 1000
        )
        let session = makeSession(transport: transport, settings: settings)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        clock.current = clock.current.addingTimeInterval(3.0)
        session.ingestLevel(rms: 0.0)
        await session.ingestAudioChunk(pcm16le: [1])
        clock.current = clock.current.addingTimeInterval(1.0)
        session.ingestLevel(rms: 0.0)

        session.toggleMute()
        await session.ingestAudioChunk(pcm16le: [Int16.max, Int16.max])
        session.toggleMute()
        session.ingestLevel(rms: 0.5)
        await session.ingestAudioChunk(pcm16le: [3, 3])

        let sent = await transport.sentTexts
        let loud = RealtimeUplinkChunk.audioBase64(fromPCM16LE: [Int16.max, Int16.max])
        XCTAssertFalse(sent.contains { $0.contains(loud) })
        XCTAssertTrue(sent.contains { $0.contains(RealtimeUplinkChunk.audioBase64(fromPCM16LE: [0, 0])) })
    }

    /// Speech resuming lifts the gate immediately — no sustained duration required, unlike
    /// engaging it — and sending picks back up.
    func testSpeechResumingLiftsTheGateAndSendingResumes() async {
        let transport = FakeVoiceRealtimeTransport()
        let settings = VoiceSettings(
            silenceDetectionEnabled: true, silenceThreshold: 0.01, silenceDurationMs: 1000
        )
        let session = makeSession(transport: transport, settings: settings)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        // Default grace is 3000ms -- advance past it, then feed 1000ms of continuous quiet.
        clock.current = clock.current.addingTimeInterval(3.0)
        session.ingestLevel(rms: 0.0)
        clock.current = clock.current.addingTimeInterval(1.0)
        session.ingestLevel(rms: 0.0)
        await session.ingestAudioChunk(pcm16le: [1, 2, 3])
        let loud = RealtimeUplinkChunk.audioBase64(fromPCM16LE: [1, 2, 3])
        let sentWhileGated = await transport.sentTexts
        XCTAssertFalse(sentWhileGated.contains { $0.contains(loud) })

        session.ingestLevel(rms: 0.5)
        await session.ingestAudioChunk(pcm16le: [4, 5, 6])
        let sentAfterResuming = await transport.sentTexts
        XCTAssertTrue(
            sentAfterResuming.last?.contains(RealtimeUplinkChunk.audioBase64(fromPCM16LE: [4, 5, 6])) == true)
    }

    /// A gate that never lifts must still end the take, or this is an open, silent socket for as
    /// long as nobody notices.
    func testAGateThatNeverLiftsEventuallyEndsTheTake() async {
        let transport = FakeVoiceRealtimeTransport()
        let settings = VoiceSettings(
            silenceDetectionEnabled: true, silenceThreshold: 0.01, silenceDurationMs: 1000
        )
        let session = makeSession(transport: transport, settings: settings)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        // Default grace is 3000ms -- advance past it, then feed 1000ms of continuous quiet to
        // actually engage the gate before the backstop's own clock can start.
        clock.current = clock.current.addingTimeInterval(3.0)
        session.ingestLevel(rms: 0.0)
        clock.current = clock.current.addingTimeInterval(1.0)
        session.ingestLevel(rms: 0.0)
        // Past the default 120s backstop, still quiet.
        clock.current = clock.current.addingTimeInterval(121.0)
        session.ingestLevel(rms: 0.0)

        await waitUntil { session.state == .idle }
        XCTAssertEqual(session.lastEndReason, .silence)
    }

    func testLoudAudioNeverGatesOrEndsTheTake() async {
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
        await session.ingestAudioChunk(pcm16le: [1, 2, 3])

        XCTAssertEqual(session.state, .recording)
        let sent = await transport.sentTexts
        XCTAssertEqual(sent.count, 1)
    }
}
