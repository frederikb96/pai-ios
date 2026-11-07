import XCTest

@testable import PAIKit

/// What the phone sends and shows for decisions: the wire a refusal travels on, the owner-only
/// gate in front of every request, and which picks are actually sent.
@MainActor
final class DecisionsTests: XCTestCase {

    override func tearDown() {
        PaiStubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Fakes and fixtures

    private func decision(
        _ number: Int, session: String = "s1", title: String = "Ship it", recommendation: String = "yes",
        updatedAt: String = "2026-09-01T08:15:00.506812+00:00"
    ) -> Decision {
        Decision(
            id: "d-\(session)-\(number)", sessionId: session, sessionTitle: "Title \(session)", number: number,
            title: title, recommendation: recommendation, updatedAt: updatedAt)
    }

    /// Answers from a script and records what it was asked. `firstRead` can hold the first
    /// `getOpenDecisions` open so a test can let a newer read overtake it.
    private final class FakeApi: DecisionsApiClient, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [String] = []
        private var _answers: [[DecisionAnswer]] = []
        var reads: [OpenDecisionsResponse] = []
        var answerError: Error?
        var heldFirstRead: CheckedContinuation<OpenDecisionsResponse, Error>?
        var holdFirstRead = false
        let firstReadStarted: AsyncStream<Void>
        private let startedSignal: AsyncStream<Void>.Continuation

        init() {
            (firstReadStarted, startedSignal) = AsyncStream<Void>.makeStream()
        }

        var requests: [String] { lock.withLock { _requests } }
        var answers: [[DecisionAnswer]] { lock.withLock { _answers } }

        func getOpenDecisions() async throws -> OpenDecisionsResponse {
            let hold = lock.withLock { () -> Bool in
                _requests.append("read")
                defer { holdFirstRead = false }
                return holdFirstRead
            }
            if hold {
                return try await withCheckedThrowingContinuation { continuation in
                    heldFirstRead = continuation
                    startedSignal.yield()
                }
            }
            return lock.withLock { reads.isEmpty ? OpenDecisionsResponse(decisions: []) : reads.removeFirst() }
        }

        func answerDecisions(sessionId: String, answers: [DecisionAnswer], clientMessageId: String) async throws
            -> AnswerDecisionsResponse
        {
            lock.withLock {
                _requests.append("answer")
                _answers.append(answers)
            }
            if let answerError { throw answerError }
            return AnswerDecisionsResponse(message: "ok", answered: [])
        }

        func withdrawDecision(sessionId: String, number: Int) async throws -> Decision {
            lock.withLock { _requests.append("withdraw") }
            return Decision(id: "x", sessionId: sessionId, number: number, title: "t", recommendation: "r")
        }
    }

    private func makeStore(_ api: FakeApi, owner: Bool = true) -> DecisionsStore {
        DecisionsStore(api: api, isOwner: { owner })
    }

    private func makeClient() throws -> PaiApiClient {
        let factory = try PaiRequestFactory(baseURL: "https://pai.example.com", tokenProvider: { "jwt" })
        return PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
    }

    // MARK: - Wire

    func testADecisionWithAnUnknownStateAndAnExtraFieldStillDecodes() async throws {
        let json = """
            {"id":"i","session_id":"s","session_title":null,"number":4,"title":"t","context":"","recommendation":"yes",
            "options":["yes","no"],"blocks":false,"state":"parked","answer":null,"created_at":"c","updated_at":"u",
            "resolved_at":null,"priority":"high"}
            """
        let decoded = try JSONDecoder().decode(Decision.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.state, .unrecognized("parked"))
        XCTAssertEqual(decoded.number, 4)
    }

    func testAnAnswerCarriesTheUpdatedAtItWasShownWithAndAFreshMessageId() async throws {
        PaiStubURLProtocol.stub = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"],
            body: Data(#"{"status":"accepted","message":"D3: yes.","duplicate":false,"answered":[]}"#.utf8))
        let client = try makeClient()
        _ = try await client.answerDecisions(
            sessionId: "s1", answers: [DecisionAnswer(number: 3, answer: "yes", updatedAt: "stamp-1")],
            clientMessageId: "m-1")

        let request = PaiStubURLProtocol.capturedRequest
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertTrue(request?.url?.path.hasSuffix("/api/session/s1/decisions/answer") ?? false)
        let sent = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(PaiStubURLProtocol.capturedBody)) as? [String: Any])
        XCTAssertEqual(sent["client_message_id"] as? String, "m-1")
        let answers = try XCTUnwrap(sent["answers"] as? [[String: Any]])
        XCTAssertEqual(answers.first?["number"] as? Int, 3)
        XCTAssertEqual(answers.first?["answer"] as? String, "yes")
        XCTAssertEqual(answers.first?["updated_at"] as? String, "stamp-1")
    }

    /// The 409 of the decision routes puts `{message, numbers}` where every other refusal has a
    /// string; the owner must read the server's sentence, not "HTTP 409".
    func testAConflictShowsTheServersMessage() async throws {
        PaiStubURLProtocol.stub = .init(
            statusCode: 409, headers: ["Content-Type": "application/json"],
            body: Data(#"{"detail":{"message":"D3 was answered meanwhile","numbers":[3]}}"#.utf8))
        let client = try makeClient()
        do {
            _ = try await client.answerDecisions(
                sessionId: "s1", answers: [DecisionAnswer(number: 3, answer: "yes")], clientMessageId: "m")
            XCTFail("expected a conflict")
        } catch let error as PaiError {
            XCTAssertEqual(error.userMessage, "D3 was answered meanwhile")
        }
    }

    func testWithdrawPostsToTheDecisionsOwnPathWithoutABody() async throws {
        PaiStubURLProtocol.stub = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"],
            body: Data(
                """
                {"decision":{"id":"i","session_id":"s1","session_title":null,"number":3,"title":"t","context":"",\
                "recommendation":"yes","options":[],"blocks":false,"state":"withdrawn","answer":null,\
                "created_at":"c","updated_at":"u","resolved_at":"r"}}
                """.utf8))
        let client = try makeClient()
        let withdrawn = try await client.withdrawDecision(sessionId: "s1", number: 3)

        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.httpMethod, "POST")
        XCTAssertTrue(
            PaiStubURLProtocol.capturedRequest?.url?.path.hasSuffix("/api/session/s1/decisions/3/withdraw") ?? false)
        XCTAssertEqual(withdrawn.state, .withdrawn)
    }

    // MARK: - Store

    /// A guest's 403 reads as a rejected credential and signs the app out, so no request may
    /// leave for one.
    func testAGuestNeverSendsARequest() async {
        let api = FakeApi()
        let store = makeStore(api, owner: false)
        await store.refresh()
        XCTAssertEqual(api.requests, [])
    }

    func testAnOlderSlowReadDoesNotOverwriteANewerOne() async {
        let api = FakeApi()
        api.holdFirstRead = true
        api.reads = [OpenDecisionsResponse(decisions: [decision(9)])]
        let store = makeStore(api)

        let slow = Task { await store.refresh() }
        for await _ in api.firstReadStarted { break }
        await store.refresh()
        XCTAssertEqual(store.open.map(\.number), [9])

        api.heldFirstRead?.resume(returning: OpenDecisionsResponse(decisions: [decision(1)]))
        await slow.value
        XCTAssertEqual(store.open.map(\.number), [9])
    }

    func testGroupsPutTheSessionWithTheNewestDecisionFirstAndSortAWithinByNumber() async {
        let api = FakeApi()
        api.reads = [
            OpenDecisionsResponse(decisions: [
                decision(5, session: "b"), decision(2, session: "a"), decision(1, session: "b"),
            ])
        ]
        let store = makeStore(api)
        await store.refresh()

        XCTAssertEqual(store.groups.map(\.sessionId), ["b", "a"])
        XCTAssertEqual(store.groups.first?.decisions.map(\.number), [1, 5])
        XCTAssertEqual(store.groups.first?.sessionTitle, "Title b")
    }

    // MARK: - List state

    func testOnlyPicksOfStillOpenDecisionsAreSentAndEachCarriesItsUpdatedAt() async {
        let state = DecisionListState()
        state.pick(1, "yes")
        state.pick(2, "no, because it is late")
        state.pick(7, "maybe")  // answered elsewhere, no longer listed

        let answers = state.pendingAnswers(for: [
            decision(2, updatedAt: "u2"), decision(1, updatedAt: "u1"),
        ])
        XCTAssertEqual(
            answers,
            [
                DecisionAnswer(number: 1, answer: "yes", updatedAt: "u1"),
                DecisionAnswer(number: 2, answer: "no, because it is late", updatedAt: "u2"),
            ])
    }

    func testAPickIsKeptWhenTheSendIsRefusedAndClearedWhenItLands() async {
        let api = FakeApi()
        let store = makeStore(api)
        let state = DecisionListState()
        let decisions = [decision(3)]
        state.pick(3, "yes")

        api.answerError = PaiError.detail("D3 was answered meanwhile", statusCode: 409)
        await state.send(sessionId: "s1", decisions: decisions, store: store)
        XCTAssertEqual(state.picked, [3: "yes"])
        XCTAssertEqual(state.errorMessage, "D3 was answered meanwhile")
        XCTAssertTrue(api.requests.contains("read"), "a refusal re-reads the list")

        api.answerError = nil
        await state.send(sessionId: "s1", decisions: decisions, store: store)
        XCTAssertEqual(state.picked, [:])
        XCTAssertNil(state.errorMessage)
    }

    func testPickingTheSameAnswerTwiceTakesItBack() async {
        let state = DecisionListState()
        state.pick(3, "yes")
        state.pick(3, "yes")
        XCTAssertNil(state.picked[3])
    }
}
