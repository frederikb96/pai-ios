import XCTest

@testable import PAIKit

@MainActor
final class SubagentControlsStoreTests: XCTestCase {
    private static let controlsJSON = """
        {"controls":{"can_nudge":true,"can_interrupt":true,"can_resume_after_interrupt":false,
        "agent_state":"running","reason":null},
        "nudges":[
        {"id":"n1","text":"first","state":"delivered","error":null,"reworded":false,"created_at":"2026-11-04T10:00:00+00:00"},
        {"id":"n2","text":"second","state":"relayed","error":null,"reworded":true,"created_at":"2026-11-04T10:01:00+00:00"},
        {"id":"n3","text":"third","state":"failed","error":"no route","reworded":false,"created_at":"2026-11-04T10:02:00+00:00"},
        {"id":"n4","text":"fourth","state":"queued","error":null,"reworded":false,"created_at":"2026-11-04T10:03:00+00:00"}]}
        """

    private static func decoded(_ json: String = controlsJSON) throws -> SubagentControlsResponse {
        try JSONDecoder().decode(SubagentControlsResponse.self, from: Data(json.utf8))
    }

    func testDecodesTheContractShapeAndKeepsAnUnknownStateReadable() async throws {
        let response = try Self.decoded()
        XCTAssertTrue(response.controls.canNudge)
        XCTAssertFalse(response.controls.canResumeAfterInterrupt)
        XCTAssertEqual(response.controls.agentState, .running)
        XCTAssertEqual(response.nudges.map(\.state), [.delivered, .relayed, .failed, .queued])
        XCTAssertTrue(response.nudges[1].reworded)

        let odd = try Self.decoded(
            Self.controlsJSON.replacingOccurrences(of: "\"running\"", with: "\"napping\"")
                .replacingOccurrences(of: "\"queued\"", with: "\"parked\""))
        XCTAssertEqual(odd.controls.agentState, .unrecognized("napping"))
        XCTAssertEqual(odd.nudges.last?.state, .unrecognized("parked"))
    }

    func testListsTheLastThreeMessagesAndPollsOnlyWhileOneIsOnItsWay() async throws {
        let api = FakeControlsApi(reads: [try Self.decoded()])
        let store = SubagentControlsStore(sessionId: "list-\(#line)", api: api)
        await store.refresh()
        XCTAssertEqual(store.listedNudges.map(\.id), ["n2", "n3", "n4"])
        XCTAssertTrue(store.hasPending)

        let settled = try Self.decoded(
            Self.controlsJSON.replacingOccurrences(of: "\"relayed\"", with: "\"delivered\"")
                .replacingOccurrences(of: "\"queued\"", with: "\"delivered\""))
        await api.setReads([settled])
        await store.refresh()
        XCTAssertFalse(store.hasPending)
    }

    func testSendClearsTheTextAndReadsAgainButAFailureKeepsIt() async throws {
        let api = FakeControlsApi(reads: [try Self.decoded()])
        let store = SubagentControlsStore(sessionId: "send-\(#line)", api: api)
        store.text = "  please stop at the tests  "
        await store.send()
        let sent = await api.sent
        XCTAssertEqual(sent, ["please stop at the tests"])
        XCTAssertEqual(store.text, "")
        XCTAssertNotNil(store.response)

        await api.failSend(with: PaiError.detail("not running", statusCode: 409))
        store.text = "again"
        await store.send()
        XCTAssertEqual(store.text, "again")
        XCTAssertEqual(store.actionError, "not running")
    }

    func testEmptyTextIsNotSent() async throws {
        let api = FakeControlsApi(reads: [try Self.decoded()])
        let store = SubagentControlsStore(sessionId: "empty-\(#line)", api: api)
        store.text = "   "
        XCTAssertFalse(store.canSend)
        await store.send()
        let sent = await api.sent
        XCTAssertEqual(sent, [])
    }

    func testInterruptClosesTheConfirmationOnlyOnSuccess() async throws {
        let api = FakeControlsApi(reads: [try Self.decoded()])
        let store = SubagentControlsStore(sessionId: "stop-\(#line)", api: api)
        store.isConfirmingInterrupt = true
        await api.failInterrupt(with: PaiError.detail("agent too old", statusCode: 409))
        await store.interrupt()
        XCTAssertTrue(store.isConfirmingInterrupt)
        XCTAssertEqual(store.actionError, "agent too old")

        await api.failInterrupt(with: nil)
        await store.interrupt()
        XCTAssertFalse(store.isConfirmingInterrupt)
        let count = await api.interrupts
        XCTAssertEqual(count, 2)
    }

    func testTheDraftOutlivesTheStoreForTheSameAgent() async {
        let id = "draft-\(#line)"
        let first = SubagentControlsStore(sessionId: id, api: FakeControlsApi(reads: []))
        first.text = "half a thought"
        let second = SubagentControlsStore(sessionId: id, api: FakeControlsApi(reads: []))
        XCTAssertEqual(second.text, "half a thought")
    }

    func testALateAnswerForAnEarlierReadIsDropped() async throws {
        let api = FakeControlsApi(reads: [try Self.decoded()])
        let store = SubagentControlsStore(sessionId: "late-\(#line)", api: api)
        await api.holdFirstRead()
        async let slow: Void = store.refresh()
        await api.waitUntilHeld()
        let newer = try Self.decoded(
            Self.controlsJSON.replacingOccurrences(of: "\"can_nudge\":true", with: "\"can_nudge\":false"))
        await api.setReads([newer])
        await store.refresh()
        await api.releaseHeld()
        await slow
        XCTAssertEqual(store.controls?.canNudge, false)
    }
}

private actor FakeControlsApi: SubagentControlsApiClient {
    private var reads: [SubagentControlsResponse]
    private(set) var sent: [String] = []
    private(set) var interrupts = 0
    private var sendError: Error?
    private var interruptError: Error?
    private var holding = false
    private var held: CheckedContinuation<Void, Never>?
    private var heldReached = false

    init(reads: [SubagentControlsResponse]) { self.reads = reads }

    func setReads(_ next: [SubagentControlsResponse]) { reads = next }
    func failSend(with error: Error?) { sendError = error }
    func failInterrupt(with error: Error?) { interruptError = error }
    func holdFirstRead() { holding = true }

    func waitUntilHeld() async {
        while !heldReached { await Task.yield() }
    }

    func releaseHeld() {
        held?.resume()
        held = nil
    }

    func getSubagentControls(sessionId: String) async throws -> SubagentControlsResponse {
        let answer = reads.first!
        if holding {
            holding = false
            heldReached = true
            await withCheckedContinuation { held = $0 }
        }
        return answer
    }

    func sendSubagentNudge(sessionId: String, text: String) async throws -> SubagentNudgeResponse {
        if let sendError { throw sendError }
        sent.append(text)
        return SubagentNudgeResponse(
            nudge: SubagentNudge(
                id: "x", text: text, state: .queued, error: nil, reworded: false, createdAt: "2026-11-04T10:00:00+00:00"
            ))
    }

    func interruptSubagent(sessionId: String) async throws -> SubagentInterruptResponse {
        interrupts += 1
        if let interruptError { throw interruptError }
        return SubagentInterruptResponse(stopped: true, named: true)
    }
}
