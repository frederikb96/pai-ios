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
        state: DecisionState = .open, updatedAt: String = "2026-09-01T08:15:00.506812+00:00"
    ) -> Decision {
        Decision(
            id: "d-\(session)-\(number)", sessionId: session, sessionTitle: "Title \(session)", number: number,
            title: title, recommendation: recommendation, state: state, updatedAt: updatedAt)
    }

    /// Answers from a script and records what it was asked. `firstRead` can hold the first
    /// `getOpenDecisions` open so a test can let a newer read overtake it.
    private final class FakeApi: DecisionsApiClient, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [String] = []
        private var _answers: [[DecisionAnswer]] = []
        var reads: [OpenDecisionsResponse] = []
        /// One session's reads in turn; once used up, a read fails and the store keeps what it has.
        var sessionReads: [SessionDecisionsResponse] = []
        var answered: [Decision] = []
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

        func getSessionDecisions(sessionId: String) async throws -> SessionDecisionsResponse {
            try lock.withLock {
                _requests.append("session \(sessionId)")
                guard !sessionReads.isEmpty else { throw PaiError.http(statusCode: 503, reason: "unavailable") }
                return sessionReads.removeFirst()
            }
        }

        func answerDecisions(sessionId: String, answers: [DecisionAnswer], clientMessageId: String) async throws
            -> AnswerDecisionsResponse
        {
            lock.withLock {
                _requests.append("answer")
                _answers.append(answers)
            }
            if let answerError { throw answerError }
            return AnswerDecisionsResponse(message: "ok", answered: answered)
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
        await store.watch(sessionId: "s1")
        await store.refresh()
        XCTAssertEqual(api.requests, [])
    }

    /// A transcript on screen keeps its session's decisions current through every refresh the
    /// stream triggers, and stops costing a read once it is gone.
    func testRefreshRereadsAWatchedSessionUntilItIsUnwatched() async {
        let api = FakeApi()
        api.sessionReads = [
            SessionDecisionsResponse(decisions: [decision(3)]),
            SessionDecisionsResponse(decisions: [decision(3, state: .answered)]),
        ]
        let store = makeStore(api)
        await store.watch(sessionId: "s1")
        XCTAssertEqual(store.bySession["s1"]?.first?.state, .open)
        await store.refresh()
        XCTAssertEqual(store.bySession["s1"]?.first?.state, .answered)

        store.unwatch(sessionId: "s1")
        await store.refresh()
        XCTAssertEqual(api.requests.filter { $0 == "session s1" }.count, 2)
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

    // MARK: - Picks shared by every surface

    /// The pin and a card inside a reply pick into one set, so one Send sends both, and each
    /// answer names the version it was picked on: the agent changing the decision since is for the
    /// server to refuse, not for the phone to paper over with the newer version.
    func testPicksFromTwoSurfacesGoOutAsOneMessageEachWithTheVersionItWasPickedOn() async {
        let api = FakeApi()
        api.reads = [OpenDecisionsResponse(decisions: [decision(1, updatedAt: "u1"), decision(2, updatedAt: "u2")])]
        api.sessionReads = [
            SessionDecisionsResponse(decisions: [decision(1, updatedAt: "u1"), decision(2, updatedAt: "u2")]),
            SessionDecisionsResponse(decisions: [decision(1, updatedAt: "u1"), decision(2, updatedAt: "u2-edited")]),
        ]
        let store = makeStore(api)
        await store.watch(sessionId: "s1")
        await store.refresh()

        let pin = DecisionListState()
        store.pick("yes", for: decision(1, updatedAt: "u1"))
        DecisionListState.useOwnWords("  not before Friday ", for: decision(2, updatedAt: "u2"), store: store)
        await store.refresh()
        await pin.send(sessionId: "s1", store: store)

        XCTAssertEqual(
            api.answers,
            [
                [
                    DecisionAnswer(number: 1, answer: "yes", updatedAt: "u1"),
                    DecisionAnswer(number: 2, answer: "not before Friday", updatedAt: "u2"),
                ]
            ])
    }

    /// The session's own listing is read in every state, so it knows a decision was answered on
    /// another device before the cross-session open list does; a pick on that one is not sent.
    func testAPickIsSentOnlyWhileItsDecisionIsOpenAsFarAsThePhoneKnows() async {
        let api = FakeApi()
        api.reads = [OpenDecisionsResponse(decisions: [decision(7), decision(8)])]
        api.sessionReads = [SessionDecisionsResponse(decisions: [decision(7, state: .answered)])]
        let store = makeStore(api)
        await store.refresh()
        await store.watch(sessionId: "s1")

        store.pick("yes", for: decision(7))
        store.pick("no", for: decision(8))
        store.pick("maybe", for: decision(9))  // in neither list
        XCTAssertEqual(store.pendingAnswers(sessionId: "s1").map(\.number), [8])
    }

    /// An answer that landed shows as answered in the reply at once, without waiting for a read,
    /// and its pick is gone.
    func testAnAnswerThatLandsResolvesItsCardAndDropsItsPick() async {
        let api = FakeApi()
        api.sessionReads = [SessionDecisionsResponse(decisions: [decision(2), decision(3)])]
        api.answered = [decision(3, state: .answered)]
        let store = makeStore(api)
        await store.watch(sessionId: "s1")
        store.pick("yes", for: decision(2))
        store.pick("yes", for: decision(3))

        try? await store.answer(sessionId: "s1", answers: [DecisionAnswer(number: 3, answer: "yes")])
        XCTAssertEqual(store.bySession["s1"]?.map(\.state), [.open, .answered])
        XCTAssertEqual(store.picked(sessionId: "s1", number: 3), nil)
        XCTAssertEqual(store.picked(sessionId: "s1", number: 2), "yes")
    }

    func testAPickIsKeptWhenTheSendIsRefusedAndClearedWhenItLands() async {
        let api = FakeApi()
        api.reads = [OpenDecisionsResponse(decisions: [decision(3)]), OpenDecisionsResponse(decisions: [decision(3)])]
        let store = makeStore(api)
        await store.refresh()
        let state = DecisionListState()
        store.pick("yes", for: decision(3))

        api.answerError = PaiError.detail("D3 was answered meanwhile", statusCode: 409)
        await state.send(sessionId: "s1", store: store)
        XCTAssertEqual(store.picked(sessionId: "s1", number: 3), "yes")
        XCTAssertEqual(state.errorMessage, "D3 was answered meanwhile")
        XCTAssertTrue(api.requests.contains("read"), "a refusal re-reads the list")

        api.answerError = nil
        await state.send(sessionId: "s1", store: store)
        XCTAssertNil(store.picked(sessionId: "s1", number: 3))
        XCTAssertNil(state.errorMessage)
    }

    func testPickingTheSameAnswerTwiceTakesItBack() async {
        let store = makeStore(FakeApi())
        store.pick("yes", for: decision(3))
        store.pick("yes", for: decision(3))
        XCTAssertNil(store.picked(sessionId: "s1", number: 3))
    }
}
