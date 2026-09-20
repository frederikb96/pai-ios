import XCTest

@testable import PAIKit

/// Same shape as `VoiceUplinkSessionTests`' own fake — an actor because `send`/`receive` are
/// called from whichever isolation context `ComputerCallSession`'s own tasks run on.
private actor FakeComputerCallTransport: VoiceSocketTransportProtocol {
    private(set) var sentFrames: [VoiceUpFrame] = []
    private(set) var sentAudioFrames: [Data] = []
    private var toReceive: [VoiceSocketMessage] = []
    private var pendingReceives: [CheckedContinuation<VoiceSocketMessage, Error>] = []
    /// Set by `failReceives` when no `receive()` call is suspended yet to fail directly — the
    /// next call to `receive()`, whenever it happens, throws this instead of waiting. Without
    /// this, a `failReceives` that races ahead of `receiveLoop`'s own next `receive()` call would
    /// otherwise be silently lost.
    private var pendingFailureDetail: String??

    func connect(url: URL) async throws {}

    func send(_ frame: VoiceUpFrame) async throws {
        sentFrames.append(frame)
    }

    func sendAudio(_ data: Data) async throws {
        sentAudioFrames.append(data)
    }

    func receive() async throws -> VoiceSocketMessage {
        if let detail = pendingFailureDetail {
            pendingFailureDetail = nil
            throw VoiceSocketTransportError.connectionLost(reason: detail)
        }
        if !toReceive.isEmpty {
            return toReceive.removeFirst()
        }
        return try await withCheckedThrowingContinuation { pendingReceives.append($0) }
    }

    func close(code: Int, reason: String?) async {}

    func enqueue(_ message: VoiceSocketMessage) {
        if let continuation = pendingReceives.first {
            pendingReceives.removeFirst()
            continuation.resume(returning: message)
        } else {
            toReceive.append(message)
        }
    }

    /// Fails every future `receive()` the way a lost connection does — matching
    /// `URLSessionVoiceSocketTransport`'s own translation of a dead socket.
    func failReceives(detail: String?) {
        if let continuation = pendingReceives.first {
            pendingReceives.removeFirst()
            continuation.resume(throwing: VoiceSocketTransportError.connectionLost(reason: detail))
        } else {
            pendingFailureDetail = .some(detail)
        }
    }
}

@MainActor
final class ComputerCallSessionTests: XCTestCase {

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition(), Date() < deadline {
            await Task.yield()
        }
    }

    private func makeSession(transport: FakeComputerCallTransport) -> ComputerCallSession {
        ComputerCallSession(
            dependencies: ComputerCallDependencies(
                makeTransport: { transport },
                socketURL: { URL(string: "wss://pai.example.com/api/voice/socket")! },
                authToken: { "token" }
            ))
    }

    /// `hello` must name no draft — that absence, plus an audio downlink, is what the backend's
    /// own `_build_engine` reads as "give this bus to Computer" rather than a dictation sink.
    func testHelloCarriesNoDraftKey() async {
        let transport = FakeComputerCallTransport()
        let session = makeSession(transport: transport)

        let startTask = Task { await session.start() }
        await waitUntil { await !transport.sentFrames.isEmpty }

        let frames = await transport.sentFrames
        guard case let .hello(transportName, caps, _, resumeToken, draftKey) = frames.first else {
            return XCTFail("expected a hello frame, got \(String(describing: frames.first))")
        }
        XCTAssertEqual(transportName, "ios")
        XCTAssertTrue(caps.audioDownlink)
        XCTAssertNil(resumeToken)
        XCTAssertNil(draftKey)

        await session.end()
        _ = await startTask.value
    }

    /// The very first `ready` opens the gate once and moves the call to `.active` — mirrors
    /// `VoiceUplinkSessionTests`' own "first ready opens the gate" case, generalized: Computer's
    /// own engine ignores `on_gate` entirely, but the client still owes the protocol's general
    /// contract.
    func testFirstReadyActivatesTheCallAndOpensTheGateOnce() async {
        let transport = FakeComputerCallTransport()
        let session = makeSession(transport: transport)

        let startTask = Task { await session.start() }
        await transport.enqueue(
            .control(.ready(resumeToken: "r1", busOwner: .computer, resumed: false, sessionId: nil)))
        await waitUntil { await transport.sentFrames.count >= 2 }

        XCTAssertEqual(session.connectionState, .active)
        XCTAssertEqual(session.busOwner, .computer)

        let frames = await transport.sentFrames
        guard case let .gate(open, reason, takeId) = frames.last else {
            return XCTFail("expected a gate frame, got \(String(describing: frames.last))")
        }
        XCTAssertTrue(open)
        XCTAssertEqual(reason, "button")
        XCTAssertNil(takeId, "Computer's own bus never dictates into a draft")

        await session.end()
        _ = await startTask.value
    }

    /// A `state` frame updates the published phase/owner/session — what the view renders,
    /// including the switchboard moving this bus into a Kai session's own call mode.
    func testStateFrameUpdatesPhaseOwnerAndSession() async {
        let transport = FakeComputerCallTransport()
        let session = makeSession(transport: transport)

        let startTask = Task { await session.start() }
        await transport.enqueue(
            .control(.ready(resumeToken: "r1", busOwner: .computer, resumed: false, sessionId: nil)))
        await waitUntil { await transport.sentFrames.count >= 2 }

        await transport.enqueue(
            .control(.state(busOwner: .call, phase: "recording", sessionId: "session-9", checkpoint: nil)))
        await waitUntil { session.busOwner == .call }

        XCTAssertEqual(session.phase, "recording")
        XCTAssertEqual(session.sessionId, "session-9")

        await session.end()
        _ = await startTask.value
    }

    /// A call-recording target for `onAudioDown`/`onClearRequested`, both `@Sendable` closure
    /// properties — an `actor`, matching `ArcSubagentLookupTests.CallRecorder`'s own shape,
    /// rather than a captured local `var` a `@Sendable` closure cannot mutate.
    private actor EventRecorder {
        private(set) var audioDown: [(ref: Int, pcm: Data)] = []
        private(set) var clearCount = 0
        func recordAudioDown(ref: Int, pcm: Data) { audioDown.append((ref, pcm)) }
        func recordClear() { clearCount += 1 }
    }

    /// A downlink audio frame is handed to the app-side player, never buffered here.
    func testDownlinkAudioIsForwardedToThePlayer() async {
        let transport = FakeComputerCallTransport()
        let session = makeSession(transport: transport)
        let recorder = EventRecorder()
        session.onAudioDown = { ref, pcm in Task { await recorder.recordAudioDown(ref: ref, pcm: pcm) } }

        let startTask = Task { await session.start() }
        await transport.enqueue(
            .control(.ready(resumeToken: "r1", busOwner: .computer, resumed: false, sessionId: nil)))
        await waitUntil { session.connectionState == .active }

        await transport.enqueue(.audio(ref: 3, pcm: Data([1, 2, 3, 4])))
        await waitUntil { await !recorder.audioDown.isEmpty }

        let received = await recorder.audioDown
        XCTAssertEqual(received.first?.ref, 3)
        XCTAssertEqual(received.first?.pcm, Data([1, 2, 3, 4]))

        await session.end()
        _ = await startTask.value
    }

    /// A `clear` frame (a barge-in) tells the app to drop buffered playback right now.
    func testClearFrameRequestsPlaybackDrop() async {
        let transport = FakeComputerCallTransport()
        let session = makeSession(transport: transport)
        let recorder = EventRecorder()
        session.onClearRequested = { Task { await recorder.recordClear() } }

        let startTask = Task { await session.start() }
        await transport.enqueue(
            .control(.ready(resumeToken: "r1", busOwner: .computer, resumed: false, sessionId: nil)))
        await waitUntil { session.connectionState == .active }

        await transport.enqueue(.control(.clear))
        await waitUntil { await recorder.clearCount > 0 }

        let clearCount = await recorder.clearCount
        XCTAssertEqual(clearCount, 1)

        await session.end()
        _ = await startTask.value
    }

    /// `notePlayed` is the real-playback receipt the backend's own barge-in tracking depends on —
    /// forwarded verbatim as a `played` frame.
    func testNotePlayedSendsAPlayedFrame() async {
        let transport = FakeComputerCallTransport()
        let session = makeSession(transport: transport)

        let startTask = Task { await session.start() }
        await transport.enqueue(
            .control(.ready(resumeToken: "r1", busOwner: .computer, resumed: false, sessionId: nil)))
        await waitUntil { session.connectionState == .active }

        await session.notePlayed(ref: 7)
        await waitUntil {
            await transport.sentFrames.contains {
                if case .played(let r) = $0 { return r == 7 }; return false
            }
        }

        let frames = await transport.sentFrames
        XCTAssertTrue(
            frames.contains {
                if case .played(let r) = $0 { return r == 7 }; return false
            })

        await session.end()
        _ = await startTask.value
    }

    /// A normal WebSocket closure (code 1000 — Computer saying "end", or the idle timeout) ends
    /// the call outright rather than being retried as an ordinary drop.
    func testAServerClosureEndsTheCallRatherThanReconnecting() async {
        let transport = FakeComputerCallTransport()
        let session = makeSession(transport: transport)

        let startTask = Task { await session.start() }
        await transport.enqueue(
            .control(.ready(resumeToken: "r1", busOwner: .computer, resumed: false, sessionId: nil)))
        await waitUntil { session.connectionState == .active }

        await transport.failReceives(detail: "close 1000: computer ended the call")
        await waitUntil { session.connectionState == .idle }

        XCTAssertEqual(session.lastEndReason, .serverClosed)
        _ = await startTask.value
    }

    /// An ordinary connection loss (no close code — a phone losing signal) moves to
    /// `.reconnecting` rather than ending the call.
    /// Real (unoverridden) reconnect/watchdog delays on purpose: `handleConnectionLost` sets
    /// `.reconnecting` synchronously, before either timer ever runs, and `end()` cancels both
    /// tasks well before their real multi-second delays would fire — overriding `sleep` to a
    /// true no-op instead turns the watchdog's own `while true { sleep; check }` loop into a
    /// tight spin with no real suspension in it, which starves this test's own task of CPU for
    /// tens of seconds rather than speeding anything up.
    func testAnOrdinaryDropReconnectsRatherThanEnding() async {
        let transport = FakeComputerCallTransport()
        let session = makeSession(transport: transport)

        let startTask = Task { await session.start() }
        await transport.enqueue(
            .control(.ready(resumeToken: "r1", busOwner: .computer, resumed: false, sessionId: nil)))
        await waitUntil { session.connectionState == .active }

        await transport.failReceives(detail: nil)
        await waitUntil { session.connectionState == .reconnecting }

        XCTAssertEqual(session.connectionState, .reconnecting)
        XCTAssertNil(session.lastEndReason)

        await session.end()
        _ = await startTask.value
    }

    /// Ending the call sends `gate close` then `bye`, and closes the transport.
    func testEndSendsGateCloseAndBye() async {
        let transport = FakeComputerCallTransport()
        let session = makeSession(transport: transport)

        let startTask = Task { await session.start() }
        await transport.enqueue(
            .control(.ready(resumeToken: "r1", busOwner: .computer, resumed: false, sessionId: nil)))
        await waitUntil { session.connectionState == .active }

        await session.end()
        _ = await startTask.value

        let frames = await transport.sentFrames
        guard frames.count >= 4 else { return XCTFail("expected hello, gate open, gate close, bye") }
        guard case .gate(false, _, _) = frames[frames.count - 2] else {
            return XCTFail("expected a gate-close frame before bye, got \(frames[frames.count - 2])")
        }
        guard case .bye = frames.last else {
            return XCTFail("expected a bye frame, got \(String(describing: frames.last))")
        }
        XCTAssertEqual(session.connectionState, .idle)
        XCTAssertEqual(session.lastEndReason, .user)
    }

    /// `ready.resumed == true` must NOT resend `gate open` — the bus/engine never detached, so
    /// re-opening it would be wrong, not just redundant. Mirrors
    /// `VoiceUplinkSessionTests.testAResumedReadyDoesNotResendGateOpen`.
    func testAResumedReadyDoesNotResendGateOpen() async {
        let transport = FakeComputerCallTransport()
        let session = makeSession(transport: transport)

        let startTask = Task { await session.start() }
        await transport.enqueue(
            .control(.ready(resumeToken: "r1", busOwner: .computer, resumed: false, sessionId: nil)))
        await waitUntil { session.connectionState == .active }

        await transport.enqueue(.control(.ready(resumeToken: "r1", busOwner: .computer, resumed: true, sessionId: nil)))
        for _ in 0..<20 { await Task.yield() }

        let frames = await transport.sentFrames
        XCTAssertEqual(frames.count, 2, "a resumed ready must not send a second gate frame")

        await session.end()
        _ = await startTask.value
    }

    /// The wire `seq` counter restarts at 0 on EVERY `ready`, including a resumed one — the same
    /// fix `VoiceUplinkSessionTests.testSeqRestartsAtZeroOnAResumedReadyToo` proves for dictation,
    /// here for Computer's own uplink.
    func testSeqRestartsAtZeroOnAResumedReadyToo() async {
        let transport = FakeComputerCallTransport()
        let session = makeSession(transport: transport)

        let startTask = Task { await session.start() }
        await transport.enqueue(
            .control(.ready(resumeToken: "r1", busOwner: .computer, resumed: false, sessionId: nil)))
        await waitUntil { session.connectionState == .active }

        await session.sendMicChunk(pcm16le: [1, 2, 3])
        await waitUntil { await transport.sentAudioFrames.count >= 1 }

        // A rotated token on the SAME bus — the case a token-comparison inference would have
        // misread as a fresh bus.
        await transport.enqueue(.control(.ready(resumeToken: "r2", busOwner: .computer, resumed: true, sessionId: nil)))
        for _ in 0..<20 { await Task.yield() }

        await session.sendMicChunk(pcm16le: [4, 5, 6])
        await waitUntil { await transport.sentAudioFrames.count >= 2 }

        let expected = VoiceSocketProtocol.packUplinkAudio(seq: 0, sampleOffset: 3, pcm16le: [4, 5, 6])
        let sentAudio = await transport.sentAudioFrames
        XCTAssertEqual(
            sentAudio.last, expected,
            "seq must restart at 0 on the new socket even though the bus resumed")

        await session.end()
        _ = await startTask.value
    }
}
