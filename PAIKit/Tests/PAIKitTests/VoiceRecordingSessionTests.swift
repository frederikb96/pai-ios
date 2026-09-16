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
        sleep: @escaping @Sendable (Duration) async -> Void = { _ in },
        // `.stable` rather than the dependencies' own `.offline` default: most of this file is
        // about what happens once a socket drops for a reason *other* than the network path
        // itself, and a reconnect attempt gated on `dependencies.health()` must actually run for
        // those scenarios to be reachable at all. Tests of the path-unsatisfied gate itself
        // override this explicitly.
        health: @escaping @Sendable () -> HealthState = { .stable }
    ) -> VoiceRecordingSession {
        let dependencies = VoiceRecordingDependencies(
            mintToken: mintToken,
            makeRealtimeTransport: { transport },
            settings: { settings },
            now: { [clock] in clock.current },
            sleep: sleep,  // instant by default — the post-commit wait loop must not slow tests down
            health: health
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

    /// Feeds enough real audio that a subsequent `committed_transcript_with_timestamps`
    /// message's word timestamps have something in `SessionTimeline` to resolve against —
    /// realistic call order, since a real connection never commits text before the audio that
    /// produced it was actually transmitted.
    private func primeTimeline(_ session: VoiceRecordingSession, seconds: Double = 1.0, sampleRate: Int = 24000) async {
        let sampleCount = Int(seconds * Double(sampleRate))
        await session.ingestAudioChunk(pcm16le: [Int16](repeating: 0, count: sampleCount), at: 0)
    }

    /// Pushes a `committed_transcript_with_timestamps` message carrying one word spanning the
    /// given connection-relative seconds — the realistic wire shape once a connection always
    /// requests timestamps, since the plain `committed_transcript` message is now ignored.
    /// `primeTimeline` must have run first, or the message resolves to no placeable word.
    private func pushCommittedWithWords(
        _ transport: FakeVoiceRealtimeTransport, text: String, startSeconds: Double = 0, endSeconds: Double = 0.05
    ) async {
        await transport.push(
            #"{"message_type":"committed_transcript_with_timestamps","text":"\#(text)","words":[{"text":"\#(text)","start":\#(startSeconds),"end":\#(endSeconds),"type":"word"}]}"#
        )
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
        await session.ingestAudioChunk(pcm16le: [1, 2, 3], at: 0)
        await session.ingestAudioChunk(pcm16le: [4, 5, 6], at: 0)
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

        await session.ingestAudioChunk(pcm16le: [9, 9, 9], at: 0)

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
        await session.ingestAudioChunk(pcm16le: [Int16.max, Int16.max, Int16.max], at: 0)

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

        await primeTimeline(session)
        await transport.push(#"{"message_type":"partial_transcript","text":"hel"}"#)
        await waitUntil { session.transcribedText == "hel" }

        await pushCommittedWithWords(transport, text: "hello there")
        await transport.push(#"{"message_type":"partial_transcript","text":"how"}"#)
        await waitUntil { session.transcribedText == "hello there how" }

        XCTAssertEqual(session.transcribedText, "hello there how")
    }

    /// The new rule the timestamped connection requires: with `include_timestamps=true` always
    /// on, the plain `committed_transcript` message is the timestamped one's un-timestamped
    /// twin, not independent text — using it too would append the same words a second time.
    func testPlainCommittedTranscriptIsIgnoredOnceTimestampsAreAlwaysRequested() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }
        await primeTimeline(session)

        await transport.push(#"{"message_type":"partial_transcript","text":"hel"}"#)
        await waitUntil { session.transcribedText == "hel" }
        await transport.push(#"{"message_type":"committed_transcript","text":"hello there"}"#)
        // The acknowledgement still clears the partial even though the text is not used.
        await waitUntil { session.transcribedText == "" }

        XCTAssertEqual(session.transcribedText, "", "the plain message's text must never be appended")
    }

    // MARK: Stop, prefixing, interruption, connection loss

    func testStopSendsACommitFrameAndTheResultIsPrefixedExactlyOnce() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }
        await primeTimeline(session)
        await pushCommittedWithWords(transport, text: "hello")
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
        await primeTimeline(session)
        await pushCommittedWithWords(transport, text: "hello")
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
        await session.ingestAudioChunk(pcm16le: [7, 7, 7], at: 0)
        let sentWhileDown = await transport.sentTexts
        XCTAssertEqual(sentWhileDown.count, 0)

        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil(async: { await transport.sentTexts.count == 1 })

        let payload = RealtimeUplinkChunk.audioBase64(fromPCM16LE: [7, 7, 7])
        let sent = await transport.sentTexts
        XCTAssertTrue(sent[0].contains(payload))
    }

    /// `previous_text` rides only the very first chunk sent after a reconnect — a second chunk
    /// on the same connection carrying it too has been observed to be rejected outright by
    /// ElevenLabs, per the protocol's own contract.
    func testPreviousTextRidesOnlyTheFirstChunkAfterAReconnect() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }
        await primeTimeline(session)
        await pushCommittedWithWords(transport, text: "hello")
        await waitUntil { session.transcribedText == "hello" }

        let sentBeforeReconnect = await transport.sentTexts.count
        await transport.fail()
        await waitUntil { session.state == .reconnecting }
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        await session.ingestAudioChunk(pcm16le: [1, 1, 1], at: 24000)
        await waitUntil(async: { await transport.sentTexts.count >= sentBeforeReconnect + 1 })
        await session.ingestAudioChunk(pcm16le: [2, 2, 2], at: 24003)
        await waitUntil(async: { await transport.sentTexts.count >= sentBeforeReconnect + 2 })

        let sent = await transport.sentTexts
        XCTAssertTrue(
            sent[sentBeforeReconnect].contains("previous_text"), "the first chunk after reconnecting must carry it"
        )
        XCTAssertFalse(
            sent[sentBeforeReconnect + 1].contains("previous_text"), "never a second time on the same connection"
        )
    }

    /// Observed against a live connection: even unrelated `previous_text` can come back with the
    /// next commit prefixed by a stray `". "` — stripped once, on whichever commit follows.
    func testALeadingArtifactFromPreviousTextIsStrippedFromTheNextCommit() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }
        await primeTimeline(session)
        await pushCommittedWithWords(transport, text: "hello")
        await waitUntil { session.transcribedText == "hello" }

        await transport.fail()
        await waitUntil { session.state == .reconnecting }
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }
        await session.ingestAudioChunk(pcm16le: [1, 1, 1], at: 24000)
        await waitUntil(async: { await transport.sentTexts.count == 1 })

        await transport.push(
            #"{"message_type":"committed_transcript_with_timestamps","text":". world","words":[{"text":".","start":0.0,"end":0.01,"type":"word"},{"text":"world","start":0.01,"end":0.5,"type":"word"}]}"#
        )
        await waitUntil { session.transcribedText == "hello world" }

        XCTAssertEqual(session.transcribedText, "hello world", "the stray leading \". \" must not survive")
        XCTAssertEqual(
            session.committedSegments.last?.words?.first?.text, "world", "the stray \".\" word is dropped too")
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

    /// ElevenLabs closes an idle session with code 1000 and an EMPTY reason — present, not
    /// absent — which is the exact close every silence gate used to turn into a lost take.
    func testIdleCloseWithAnEmptyReasonReconnects() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        await transport.fail(closeReason: "")
        await waitUntil { session.state == .reconnecting }

        XCTAssertNil(session.lastEndReason, "must not have ended the take")
        XCTAssertNil(session.lastDisconnectDetail, "an empty reason says nothing worth showing")
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

    /// A failure a retry cannot fix stops transcription attempts straight away rather than
    /// spending reconnects on a token or quota that will be refused every time — but it must
    /// never end the take itself: capture keeps accepting audio, and only an explicit `stop()`
    /// closes it out.
    func testQuotaExceededStopsTranscriptionAttemptsWithoutEndingTheTake() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        await transport.push(#"{"message_type":"quota_exceeded","message":"out of credits"}"#)
        await waitUntil { session.state == .transcriptionStopped }

        XCTAssertNil(session.lastEndReason, "the take has not ended yet")
        XCTAssertEqual(session.lastProtocolErrorMessage, "quota_exceeded: out of credits")
        let connectCalls = await transport.connectCallCount
        XCTAssertEqual(connectCalls, 1, "no reconnect is ever attempted after a fatal error")

        // Audio is still accepted — nowhere for it to go, but the call must not be rejected.
        await session.ingestAudioChunk(pcm16le: [1, 2, 3], at: 100_000)

        await session.stop(reason: .user)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.lastEndReason, .user)
    }

    /// The scenario the block leader's report calls out by name: the earlier design ended the
    /// whole take once `ReconnectPolicy` ran out of attempts. It no longer has a ceiling at all —
    /// dozens of consecutive failures to even connect must still leave the take reconnecting,
    /// rather than the five-attempt give-up the ported Android policy used to enforce.
    func testReconnectNeverGivesUpEvenAfterManyConsecutiveFailures() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        // Every attempt from here fails to even connect — the fake keeps throwing on `connect()`
        // forever, so the retry loop chains through `handleConnectionLost` on its own with no
        // further test intervention needed.
        await transport.setConnectError(URLError(.cannotConnectToHost))
        await transport.fail()

        // Twenty attempts — four times the old five-attempt ceiling.
        await waitUntil(async: { await transport.connectCallCount >= 20 }, iterations: 500_000)

        let connectCalls = await transport.connectCallCount
        XCTAssertGreaterThanOrEqual(connectCalls, 20)
        XCTAssertEqual(session.state, .reconnecting)
        XCTAssertNil(session.lastEndReason, "an unbounded reconnect must never end the take on its own")
    }

    func testProtocolErrorMessageStopsTranscriptionAttemptsAndRecordsTheMessage() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        await transport.push(#"{"message_type":"error","message":"quota exceeded"}"#)
        await waitUntil { session.state == .transcriptionStopped }

        XCTAssertNil(session.lastEndReason, "the take has not ended yet")
        XCTAssertEqual(session.lastProtocolErrorMessage, "quota exceeded")
        let closeCalls = await transport.closeCallCount
        XCTAssertEqual(closeCalls, 1, "the dead-end socket is closed rather than left dangling")
    }

    /// The other half of `ReconnectPolicy` losing its ceiling: while the network path itself is
    /// unsatisfied, no attempt is made at all — a mint round trip that cannot succeed must never
    /// be spent, and the take must simply keep waiting rather than reconnecting into nothing.
    func testNoReconnectAttemptWhileThePathIsUnsatisfied() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport, health: { .offline })
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        await transport.fail()
        await waitUntil { session.state == .reconnecting }

        // Give the retry loop plenty of scheduler turns to have attempted something.
        for _ in 0..<500 { await Task.yield() }

        XCTAssertEqual(session.state, .reconnecting, "still trying, not given up")
        let connectCalls = await transport.connectCallCount
        XCTAssertEqual(connectCalls, 1, "only the original connect — no attempt while offline")
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
        await session.ingestAudioChunk(pcm16le: [Int16.max, Int16.max, Int16.max], at: 0)
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
        await session.ingestAudioChunk(pcm16le: [5, 5, 5], at: 0)
        clock.current = clock.current.addingTimeInterval(1.0)
        session.ingestLevel(rms: 0.0)  // gates, one second after the last real frame

        let interval = TimeInterval(VoiceRealtimeProtocol.keepaliveIntervalMs) / 1000
        clock.current = clock.current.addingTimeInterval(interval - 1.5)
        await session.ingestAudioChunk(pcm16le: [9, 9, 9], at: 0)
        let beforeInterval = await transport.sentTexts
        XCTAssertEqual(beforeInterval.count, 1, "only the real frame before the gate")

        clock.current = clock.current.addingTimeInterval(0.5)
        await session.ingestAudioChunk(pcm16le: [9, 9, 9], at: 0)
        let atInterval = await transport.sentTexts
        XCTAssertEqual(atInterval.count, 2)
        XCTAssertTrue((atInterval.last ?? "").contains(RealtimeUplinkChunk.audioBase64(fromPCM16LE: [0, 0, 0])))

        clock.current = clock.current.addingTimeInterval(interval - 0.1)
        await session.ingestAudioChunk(pcm16le: [9, 9, 9], at: 0)
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
        await session.ingestAudioChunk(pcm16le: [1], at: 0)
        clock.current = clock.current.addingTimeInterval(1.0)
        session.ingestLevel(rms: 0.0)

        // 100ms chunks at 24kHz, each marked by its value; the preroll holds 300ms of them.
        let chunkSamples = 2400
        for marker in Int16(10)...Int16(14) {
            await session.ingestAudioChunk(pcm16le: [Int16](repeating: marker, count: chunkSamples), at: 0)
        }
        let sentBeforeResume = await transport.sentTexts.count

        session.ingestLevel(rms: 0.5)
        await session.ingestAudioChunk(pcm16le: [Int16](repeating: 20, count: chunkSamples), at: 0)

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
        await session.ingestAudioChunk(pcm16le: [8, 8, 8], at: 0)

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
        await session.ingestAudioChunk(pcm16le: [1], at: 0)
        clock.current = clock.current.addingTimeInterval(1.0)
        session.ingestLevel(rms: 0.0)

        session.toggleMute()
        await session.ingestAudioChunk(pcm16le: [Int16.max, Int16.max], at: 0)
        session.toggleMute()
        session.ingestLevel(rms: 0.5)
        await session.ingestAudioChunk(pcm16le: [3, 3], at: 0)

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
        await session.ingestAudioChunk(pcm16le: [1, 2, 3], at: 0)
        let loud = RealtimeUplinkChunk.audioBase64(fromPCM16LE: [1, 2, 3])
        let sentWhileGated = await transport.sentTexts
        XCTAssertFalse(sentWhileGated.contains { $0.contains(loud) })

        session.ingestLevel(rms: 0.5)
        await session.ingestAudioChunk(pcm16le: [4, 5, 6], at: 0)
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
        await session.ingestAudioChunk(pcm16le: [1, 2, 3], at: 0)

        XCTAssertEqual(session.state, .recording)
        let sent = await transport.sentTexts
        XCTAssertEqual(sent.count, 1)
    }

    // MARK: Durable pipeline — provisional text, uncovered ranges, burst demotion

    /// The first of the four behaviours the block leader's report names: a drop with an
    /// in-flight partial must keep it as provisional text rather than discarding it — never
    /// folded into a committed segment, since nothing has actually confirmed it yet.
    func testDropKeepsTheInFlightPartialAsProvisionalText() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }
        await primeTimeline(session)

        await transport.push(#"{"message_type":"partial_transcript","text":"partial words"}"#)
        await waitUntil { session.transcribedText == "partial words" }
        XCTAssertEqual(session.provisionalText, "", "not provisional while the socket is still alive")

        await transport.fail()
        await waitUntil { session.state == .reconnecting }

        XCTAssertEqual(session.provisionalText, "partial words")
        XCTAssertNotNil(session.provisionalRange)
        XCTAssertTrue(session.committedSegments.isEmpty, "never folded into a committed segment")
    }

    /// The second: a drop must leave the uncovered stretch derivable as a gap. Nothing here
    /// stores a gap directly — `committedSegments` simply never grows to cover what a live
    /// socket never got to transcribe, which is exactly what `TranscriptLedger.derivedGaps`
    /// (proven separately in `TranscriptLedgerTests`) turns into a gap once fed
    /// `capturedUpTo` alongside it.
    func testDropLeavesTheUncoveredRangeDerivableAsAGap() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        await session.ingestAudioChunk(pcm16le: [Int16](repeating: 5, count: 24000), at: 0)
        await waitUntil(async: { await transport.sentTexts.count == 1 })

        await transport.fail()
        await waitUntil { session.state == .reconnecting }

        XCTAssertTrue(session.committedSegments.isEmpty, "nothing was ever committed for this audio")
        let ledger = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 24000, draftKey: "s", preText: "",
            segments: session.committedSegments
        )
        let gaps = ledger.derivedGaps(capturedUpTo: session.capturedUpTo)
        XCTAssertEqual(gaps.map(\.range), [0..<session.capturedUpTo])
    }

    /// The fourth: a fatal protocol error must not stop `ingestAudioChunk` from accepting audio
    /// — `capturedUpTo` keeps advancing even with no transport to send to, since a caller's own
    /// gap derivation depends on it reflecting everything actually captured.
    func testFatalErrorStillAcceptsAudioAndAdvancesCapturedUpTo() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        await transport.push(#"{"message_type":"quota_exceeded","message":"out of credits"}"#)
        await waitUntil { session.state == .transcriptionStopped }
        XCTAssertEqual(session.capturedUpTo, 0)

        await session.ingestAudioChunk(pcm16le: [1, 2, 3, 4], at: 0)
        XCTAssertEqual(session.capturedUpTo, 4)
        XCTAssertEqual(session.state, .transcriptionStopped, "still not reconnecting — nothing to reconnect for")
        let connectCalls = await transport.connectCallCount
        XCTAssertEqual(connectCalls, 1, "no attempt is ever made after a fatal error")
    }

    /// The sharp case named by row order in the block leader's report: a stretch that survives
    /// two consecutive live-socket bursts without ever being covered must not be burst a third
    /// time. The original real send plus exactly two re-bursts is three occurrences of the same
    /// payload — a fourth would mean the demotion never took effect.
    func testTheBurstTailIsNotResentAThirdTimeAfterTwoFailedAttempts() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 24000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        let marker: Int16 = 42
        let samples = [Int16](repeating: marker, count: 2400)  // 0.1s at 24kHz — well inside the tail
        await session.ingestAudioChunk(pcm16le: samples, at: 0)
        await waitUntil(async: { await transport.sentTexts.count == 1 })
        let payload = RealtimeUplinkChunk.audioBase64(fromPCM16LE: samples)

        func occurrences() async -> Int {
            await transport.sentTexts.filter { $0.contains(payload) }.count
        }

        // Drop, reconnect (burst #1) — `waitUntil { state == .recording }` alone would race the
        // burst itself, since `state` flips to `.recording` before the async burst/flush run;
        // waiting for the payload count is what actually confirms the burst happened.
        await transport.fail()
        await waitUntil { session.state == .reconnecting }
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil(async: { await occurrences() == 2 })

        // Drop again before anything commits, reconnect (burst #2).
        await transport.fail()
        await waitUntil { session.state == .reconnecting }
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil(async: { await occurrences() == 3 })

        // A third drop and reconnect must not burst again — the range is demoted instead.
        await transport.fail()
        await waitUntil { session.state == .reconnecting }
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }
        for _ in 0..<200 { await Task.yield() }

        let finalOccurrences = await occurrences()
        XCTAssertEqual(finalOccurrences, 3, "the original send plus exactly two re-bursts, never a third")
    }

    // MARK: Ordinary pauses on a perfectly clean connection

    /// The regression a clean take's own pauses used to trigger: three one-second chunks, one
    /// word spoken in the middle half of each, every word committed live, nothing ever dropped.
    /// Deriving coverage from word extents used to read the silence between words as four
    /// separate "gaps" on a connection that never had a single problem — the acknowledgment model
    /// must show none at all, since every one of those seconds was sent and acknowledged.
    func testACleanTakeWithOrdinaryPausesBetweenWordsHasNoGaps() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 16000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        for second in 0..<3 {
            let sentBefore = await transport.sentTexts.count
            await session.ingestAudioChunk(pcm16le: [Int16](repeating: 100, count: 16000), at: second * 16000)
            await waitUntil(async: { await transport.sentTexts.count > sentBefore })

            // A word spoken in the middle half of the second, exactly as a real VAD commit would
            // report it — the point being that the quarter-second of silence on either side of
            // the word is never itself transcribed, only sent and acknowledged.
            let wordStart = Double(second) + 0.25
            let wordEnd = Double(second) + 0.75
            await transport.push(
                #"{"message_type":"committed_transcript_with_timestamps","text":"w\#(second)","words":[{"text":"w\#(second)","start":\#(wordStart),"end":\#(wordEnd),"type":"word"}]}"#
            )
            await waitUntil { session.committedSegments.count == second + 1 }
        }

        let ledger = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: "s", preText: "",
            segments: session.committedSegments, acknowledged: session.acknowledgedRanges
        )
        let gaps = ledger.derivedGaps(capturedUpTo: session.capturedUpTo)
        XCTAssertTrue(gaps.isEmpty, "an ordinary pause between committed words must never read as a gap")
    }

    // MARK: - pendingLiveRange: a healthy connection's still-uncommitted tail is not yet a gap

    func testPendingLiveRangeIsNilBeforeRecordingEverStarts() {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        XCTAssertNil(session.pendingLiveRange)
    }

    /// The exact shape a call mode cycle's own one-second ledger write hits on every ordinary
    /// turn: audio keeps arriving, nothing has committed yet, the socket is perfectly healthy.
    /// Without excluding this, `TranscriptLedger.derivedGaps` reads it as an open gap and the
    /// backfill loop starts batch-transcribing speech ElevenLabs was about to commit on its own.
    func testPendingLiveRangeCoversWhatHasBeenCapturedButNotYetAcknowledgedWhileRecording() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 16000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        await session.ingestAudioChunk(pcm16le: [Int16](repeating: 100, count: 16000), at: 0)
        await waitUntil { session.capturedUpTo == 16000 }

        XCTAssertEqual(session.pendingLiveRange, 0..<16000, "nothing has committed yet, so all of it is pending")

        let ledger = TranscriptLedger(takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: "s", preText: "")
            .folding(
                liveSegments: session.committedSegments, capturedUpTo: session.capturedUpTo,
                newlyAcknowledged: session.acknowledgedRanges, pendingLiveRange: session.pendingLiveRange)
        XCTAssertTrue(ledger.gaps.isEmpty, "a healthy connection's own in-flight tail must not read as a gap")

        // The same fold with no exclusion is what the pipeline used to do — documenting the bug
        // this property fixes, not merely its absence.
        let withoutExclusion = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: "s", preText: ""
        )
        .folding(
            liveSegments: session.committedSegments, capturedUpTo: session.capturedUpTo,
            newlyAcknowledged: session.acknowledgedRanges)
        XCTAssertEqual(withoutExclusion.gaps.map(\.range), [0..<16000])
    }

    /// A commit narrows `pendingLiveRange` to whatever is left after it — the acknowledged
    /// stretch is never pending again, only the newer audio sent since.
    func testPendingLiveRangeShrinksToAfterTheLastCommitOnceOneArrives() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 16000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }
        await primeTimeline(session, seconds: 0.5, sampleRate: 16000)
        await waitUntil(async: { await transport.sentTexts.count > 0 })

        await pushCommittedWithWords(transport, text: "hi", startSeconds: 0, endSeconds: 0.3)
        await waitUntil { !session.acknowledgedRanges.isEmpty }

        await session.ingestAudioChunk(pcm16le: [Int16](repeating: 100, count: 16000), at: 8000)
        await waitUntil { session.capturedUpTo == 24000 }

        let acknowledgedUpTo = session.acknowledgedRanges.last?.upperBound ?? 0
        XCTAssertEqual(session.pendingLiveRange, acknowledgedUpTo..<24000)
    }

    /// The instant a drop moves this out of `.recording`, the same stretch is no longer merely
    /// "not yet due" — it is exactly what backfill exists to heal, so this must stop excluding it.
    func testPendingLiveRangeIsNilOnceTheConnectionDrops() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        await session.start(hardwareSampleRate: 16000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }
        await session.ingestAudioChunk(pcm16le: [Int16](repeating: 100, count: 16000), at: 0)
        await waitUntil { session.capturedUpTo == 16000 }
        XCTAssertNotNil(session.pendingLiveRange)

        await transport.fail()
        await waitUntil { session.state == .reconnecting }
        XCTAssertNil(session.pendingLiveRange, "a dropped connection's tail is a real gap, not a pending one")
    }

    // MARK: - canIngestAudio

    func testCanIngestAudioIsFalseBeforeStartAndTrueOnceRecording() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport)
        XCTAssertFalse(session.canIngestAudio)
        await session.start(hardwareSampleRate: 16000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }
        XCTAssertTrue(session.canIngestAudio)
    }

    /// `stop()` moves the session into `.stopping` while it waits out the final commit —
    /// `ingestAudioChunk` (and therefore `canIngestAudio`) must say so, since a caller that kept
    /// counting audio fed here anyway would inflate its own bookkeeping with dead air the session
    /// itself silently drops.
    func testCanIngestAudioIsFalseWhileStoppingWaitsOnTheFinalCommit() async {
        let transport = FakeVoiceRealtimeTransport()
        let session = makeSession(transport: transport, sleep: { _ in await Task.yield() })
        await session.start(hardwareSampleRate: 16000)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        let stopTask = Task { await session.stop(reason: .user) }
        await waitUntil { session.state == .stopping }
        XCTAssertFalse(session.canIngestAudio)
        await transport.push(#"{"message_type":"committed_transcript","text":""}"#)
        await stopTask.value
    }
}
