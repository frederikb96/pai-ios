import XCTest

@testable import PAIKit

/// A fake `VoiceSocketTransportProtocol` a test can feed frames into and read sent frames back
/// out of — an actor because `send`/`receive` are called from whichever isolation context
/// `VoiceUplinkSession`'s own tasks run on, and this needs to be safe to call from more than one
/// at once.
private actor FakeVoiceSocketTransport: VoiceSocketTransportProtocol {
    private(set) var sentFrames: [VoiceUpFrame] = []
    private var toReceive: [VoiceSocketMessage] = []
    private var pendingReceives: [CheckedContinuation<VoiceSocketMessage, Error>] = []

    func connect(url: URL) async throws {}

    func send(_ frame: VoiceUpFrame) async throws {
        sentFrames.append(frame)
    }

    func sendAudio(_ data: Data) async throws {}

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
        await transport.enqueue(.control(.ready(resumeToken: "r1", busOwner: .transcription, sessionId: nil)))

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

    /// A resend of `gate open` past the resume grace window (a fresh bus mid-take) must NOT carry
    /// the same `take_id` a second time — `write_draft_region`'s stale-`seq` guard would silently
    /// drop every word this reconnected engine delivers, since its own `seq` resets to 0 while the
    /// region this `take_id` already named may hold a higher one. See this file's own commit for
    /// the full reasoning; a fresh, server-minted id is the safe fallback until that interaction
    /// is confirmed to be handled server-side.
    func testASecondGateOpenWithinTheSameTakeDoesNotRepeatTheTakeId() async {
        let transport = FakeVoiceSocketTransport()
        let session = makeSession(transport: transport)

        let startTask = Task { await session.start(draftKey: "session-1", takeId: "take-1") }
        await transport.enqueue(.control(.ready(resumeToken: "r1", busOwner: .transcription, sessionId: nil)))
        await waitUntil { await transport.sentFrames.count >= 2 }

        // A second `ready` with a DIFFERENT resume token is what `isFreshBus` reads as a fresh
        // bus — the same signal a real reconnect past the grace window produces.
        await transport.enqueue(.control(.ready(resumeToken: "r2", busOwner: .transcription, sessionId: nil)))
        await waitUntil { await transport.sentFrames.count >= 3 }

        let frames = await transport.sentFrames
        guard case .gate(_, _, let secondTakeId) = frames.last else {
            return XCTFail("expected a second gate frame, got \(String(describing: frames.last))")
        }
        XCTAssertNil(secondTakeId, "a reopen within the same take must not repeat the first gate's take_id")

        await session.stop()
        _ = await startTask.value
    }
}
