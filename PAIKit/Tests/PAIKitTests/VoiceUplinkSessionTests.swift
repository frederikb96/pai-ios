import XCTest

@testable import PAIKit

/// A fake `VoiceSocketTransportProtocol` a test can feed frames into and read sent frames back
/// out of — an actor because `send`/`receive` are called from whichever isolation context
/// `VoiceUplinkSession`'s own tasks run on, and this needs to be safe to call from more than one
/// at once.
private actor FakeVoiceSocketTransport: VoiceSocketTransportProtocol {
    private(set) var sentFrames: [VoiceUpFrame] = []
    private(set) var sentAudioFrames: [Data] = []
    private var toReceive: [VoiceSocketMessage] = []
    private var pendingReceives: [CheckedContinuation<VoiceSocketMessage, Error>] = []

    func connect(url: URL) async throws {}

    func send(_ frame: VoiceUpFrame) async throws {
        sentFrames.append(frame)
    }

    func sendAudio(_ data: Data) async throws {
        sentAudioFrames.append(data)
    }

    /// Delivers whatever `enqueue(_:)` has queued, in order — once exhausted, waits forever
    /// rather than throwing, matching a real connection that has nothing further to say. The test
    /// ends (and the continuation is simply never resumed) before that matters.
    func receive() async throws -> VoiceSocketMessage {
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
}

@MainActor
final class VoiceUplinkSessionTests: XCTestCase {

    /// Polls rather than sleeping — see `DraftStoreTests`'s identical helper.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition(), Date() < deadline {
            await Task.yield()
        }
    }

    private func makeSession(transport: FakeVoiceSocketTransport) -> VoiceUplinkSession {
        VoiceUplinkSession(
            dependencies: VoiceUplinkDependencies(
                makeTransport: { transport },
                socketURL: { URL(string: "wss://pai.example.com/api/voice/socket")! },
                authToken: { "token" }
            ))
    }

    /// The bug this whole test exists to catch: a take that never sends `gate open` is a take the
    /// backend's `DraftRegionSink` never calls `start_take()` for, so every word transcribed from
    /// it is silently dropped — the very first `ready`, on a brand-new connection with nothing
    /// captured yet, MUST still open the gate, not just a reconnect that finds something already
    /// in flight.
    func testTheFirstReadyOnABrandNewConnectionOpensTheGate() async {
        let transport = FakeVoiceSocketTransport()
        let session = makeSession(transport: transport)

        let startTask = Task { await session.start(draftKey: "session-1", takeId: "take-1") }
        await transport.enqueue(
            .control(.ready(resumeToken: "r1", busOwner: .transcription, resumed: false, sessionId: nil)))

        await waitUntil { await transport.sentFrames.count >= 2 }
        let frames = await transport.sentFrames
        guard case .gate(let open, let reason, let takeId) = frames.last else {
            return XCTFail("expected a gate frame, got \(String(describing: frames.last))")
        }
        XCTAssertTrue(open)
        XCTAssertEqual(reason, "button")
        XCTAssertEqual(takeId, "take-1", "the take's own id must ride the very first gate open")

        await session.stop()
        _ = await startTask.value
    }

    /// A resend of `gate open` past the resume grace window (a fresh bus mid-take, `ready.resumed
    /// == false`) must NOT carry the same `take_id` a second time — `write_draft_region`'s
    /// stale-`seq` guard would silently drop every word this reconnected engine delivers, since
    /// its own `seq` resets to 0 while the region this `take_id` already named may hold a higher
    /// one. See this file's own commit for the full reasoning; a fresh, server-minted id is the
    /// safe fallback until that interaction is confirmed to be handled server-side.
    func testASecondGateOpenWithinTheSameTakeDoesNotRepeatTheTakeId() async {
        let transport = FakeVoiceSocketTransport()
        let session = makeSession(transport: transport)

        let startTask = Task { await session.start(draftKey: "session-1", takeId: "take-1") }
        await transport.enqueue(
            .control(.ready(resumeToken: "r1", busOwner: .transcription, resumed: false, sessionId: nil)))
        await waitUntil { await transport.sentFrames.count >= 2 }

        // `resumed: false` a second time is what a reconnect past the grace window answers with —
        // a genuinely fresh bus, whatever the resume token happens to do.
        await transport.enqueue(
            .control(.ready(resumeToken: "r2", busOwner: .transcription, resumed: false, sessionId: nil)))
        await waitUntil { await transport.sentFrames.count >= 3 }

        let frames = await transport.sentFrames
        guard case .gate(_, _, let secondTakeId) = frames.last else {
            return XCTFail("expected a second gate frame, got \(String(describing: frames.last))")
        }
        XCTAssertNil(secondTakeId, "a reopen within the same take must not repeat the first gate's take_id")

        await session.stop()
        _ = await startTask.value
    }

    /// `ready.resumed == true` must NOT resend `gate open` — the bus/engine never detached, so
    /// re-opening it would be wrong, not just redundant.
    func testAResumedReadyDoesNotResendGateOpen() async {
        let transport = FakeVoiceSocketTransport()
        let session = makeSession(transport: transport)

        let startTask = Task { await session.start(draftKey: "session-1", takeId: "take-1") }
        await transport.enqueue(
            .control(.ready(resumeToken: "r1", busOwner: .transcription, resumed: false, sessionId: nil)))
        await waitUntil { await transport.sentFrames.count >= 2 }

        await transport.enqueue(
            .control(.ready(resumeToken: "r1", busOwner: .transcription, resumed: true, sessionId: nil)))
        // Nothing further should ever be sent for this `ready` — wait past a couple of scheduler
        // turns rather than a fixed frame count, since the assertion is an absence.
        for _ in 0..<20 { await Task.yield() }

        let frames = await transport.sentFrames
        XCTAssertEqual(frames.count, 2, "a resumed ready must not send a second gate frame")

        await session.stop()
        _ = await startTask.value
    }

    /// The wire `seq` counter restarts at 0 on EVERY `ready`, including a resumed one — the
    /// bug a rotated resume token could previously hide, since `isFreshBus` used to be inferred
    /// from token identity rather than read off `resumed` directly.
    func testSeqRestartsAtZeroOnAResumedReadyToo() async {
        let transport = FakeVoiceSocketTransport()
        let session = makeSession(transport: transport)

        let startTask = Task { await session.start(draftKey: "session-1", takeId: "take-1") }
        await transport.enqueue(
            .control(.ready(resumeToken: "r1", busOwner: .transcription, resumed: false, sessionId: nil)))
        await waitUntil { await transport.sentFrames.count >= 2 }

        await session.ingestAudioChunk(pcm16le: [1, 2, 3], at: 0)
        await waitUntil { await transport.sentAudioFrames.count >= 1 }

        // A rotated token on the SAME bus — the case the old token-comparison inference would
        // have misread as a fresh bus. `resumed: true` must not add a second gate frame.
        await transport.enqueue(
            .control(.ready(resumeToken: "r2", busOwner: .transcription, resumed: true, sessionId: nil)))
        for _ in 0..<20 { await Task.yield() }
        let framesAfterResume = await transport.sentFrames
        XCTAssertEqual(framesAfterResume.count, 2, "a resumed ready must not send a second gate frame")

        await session.ingestAudioChunk(pcm16le: [4, 5, 6], at: 3)
        await waitUntil { await transport.sentAudioFrames.count >= 2 }

        let expected = VoiceSocketProtocol.packUplinkAudio(seq: 0, sampleOffset: 3, pcm16le: [4, 5, 6])
        let sentAudio = await transport.sentAudioFrames
        XCTAssertEqual(
            sentAudio.last, expected,
            "seq must restart at 0 on the new socket even though the bus resumed")

        await session.stop()
        _ = await startTask.value
    }
}
