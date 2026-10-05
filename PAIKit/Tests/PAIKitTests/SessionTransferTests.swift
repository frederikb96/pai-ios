import XCTest

@testable import PAIKit

private let sessionJSON = """
    {"id":"%@","session_type":"claude","status":"active","state":"ready","blocker":null,
     "title":null,"title_locked":null,"initial_message":null,"session_tokens":0,
     "claude_session_id":"c1","cse_id":null,"created_at":null,"updated_at":null,
     "last_activity_at":null,"working_dir":null,"agent":"laptop"%@}
    """

private func machine(_ slug: String, online: Bool = true) -> Machine {
    Machine(
        slug: slug, displayName: slug.capitalized, online: online, lastSeenAt: nil, ingestEnabled: true,
        capabilities: .init(fastSessions: false, reboot: false, shell: false, rcLocal: false), sessionTypes: [])
}

final class SessionTransferWireTests: XCTestCase {

    override func tearDown() {
        PaiStubURLProtocol.reset()
        super.tearDown()
    }

    func testSessionDecodesBothTransferFieldsOntoTheRightProperty() throws {
        let json = String(
            format: sessionJSON, "s1",
            #","transferred_to_session_id":"s2","transferred_at":"2026-10-05T12:00:00.123456+00:00""#)
        let session = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.transferredToSessionId, "s2")
        XCTAssertEqual(session.transferredAt, "2026-10-05T12:00:00.123456+00:00")
    }

    /// An older backend sends neither key, and a null is the normal answer for a session that
    /// lives where it started.
    func testSessionWithoutTheFieldsOrWithNullsReadsAsNotTransferred() throws {
        let absent = try JSONDecoder().decode(
            Session.self, from: Data(String(format: sessionJSON, "s1", "").utf8))
        XCTAssertNil(absent.transferredToSessionId)
        let nulls = try JSONDecoder().decode(
            Session.self,
            from: Data(
                String(format: sessionJSON, "s1", #","transferred_to_session_id":null,"transferred_at":null"#).utf8))
        XCTAssertNil(nulls.transferredToSessionId)
        XCTAssertNil(nulls.transferredAt)
    }

    /// `withLiveStatus` and `withPinnedAt` rebuild the session from its own fields; a field they
    /// forgot would be reset on the first status frame or pin toggle.
    func testTheFieldsSurviveTheRebuildFromSelfInitialisers() {
        let marked = Session.fixture(transferredToSessionId: "s2", transferredAt: "2026-10-05T12:00:00+00:00")
        let live = marked.withLiveStatus(
            state: .ready, blocker: nil, turnState: nil, displayState: nil, activityCounts: nil,
            secretGrantable: nil, secretPrompt: nil, liveModel: nil)
        XCTAssertEqual(live.transferredToSessionId, "s2")
        XCTAssertEqual(live.transferredAt, "2026-10-05T12:00:00+00:00")
        let pinned = marked.withPinnedAt("2026-10-05T13:00:00+00:00")
        XCTAssertEqual(pinned.transferredToSessionId, "s2")
        XCTAssertEqual(pinned.transferredAt, "2026-10-05T12:00:00+00:00")
    }

    func testTransferResponseDecodesTheNewSessionRowAndTheWarnings() throws {
        let body = """
            {"status":"transferred","snapshot":true,"warnings":["working directory missing on the target"],
             "session":\(String(format: sessionJSON, "s2", ""))}
            """
        let response = try JSONDecoder().decode(TransferResponse.self, from: Data(body.utf8))
        XCTAssertTrue(response.snapshot)
        XCTAssertEqual(response.warnings, ["working directory missing on the target"])
        XCTAssertEqual(response.session.id, "s2")
    }

    /// Path, verb, the two body keys by their wire names, and a request timeout far above the 60 s
    /// default: the backend sends nothing while it relays, so the default would abandon a transfer
    /// that goes on to succeed.
    func testTheRequestCarriesTheBodyAndWaitsLongerThanTheDefaultTimeout() async throws {
        let body = """
            {"status":"transferred","snapshot":false,"warnings":[],"session":\(String(format: sessionJSON, "s2", ""))}
            """
        PaiStubURLProtocol.stub = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
        let factory = try PaiRequestFactory(baseURL: "https://pai.example.com", tokenProvider: { "jwt" })
        let client = PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())

        _ = try await client.transferSession(sessionId: "s1", toAgent: "laptop", force: true)

        let request = try XCTUnwrap(PaiStubURLProtocol.capturedRequest)
        XCTAssertEqual(request.url?.path, "/api/session/s1/transfer")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertGreaterThan(request.timeoutInterval, 60)
        let sent = String(data: PaiStubURLProtocol.capturedBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(sent.contains(#""to_agent":"laptop""#), sent)
        XCTAssertTrue(sent.contains(#""force":true"#), sent)
    }

    /// A refusal's `detail` is what the web shows verbatim, so it has to survive to `userMessage`.
    func testARefusalSurfacesTheServersDetailVerbatim() async throws {
        PaiStubURLProtocol.stub = .init(
            statusCode: 409, headers: ["Content-Type": "application/json"],
            body: Data(#"{"detail":"The other machine is offline.","code":"agent_offline"}"#.utf8))
        let factory = try PaiRequestFactory(baseURL: "https://pai.example.com", tokenProvider: { "jwt" })
        let client = PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
        do {
            _ = try await client.transferSession(sessionId: "s1", toAgent: "laptop", force: false)
            XCTFail("a 409 must throw")
        } catch let error as PaiError {
            XCTAssertEqual(error.userMessage, "The other machine is offline.")
        }
    }
}

final class SessionTransferRuleTests: XCTestCase {

    private let both = [machine("vm"), machine("laptop")]

    func testOfferedForAnOwnersConversationWithSomewhereToSendIt() {
        XCTAssertTrue(
            SessionTransfer.isAvailable(for: .fixture(), isOwner: true, machines: both))
    }

    /// One predicate per clause of the rule, each failing alone.
    func testEachClauseOfTheRuleWithholdsTheAction() {
        XCTAssertFalse(SessionTransfer.isAvailable(for: .fixture(), isOwner: false, machines: both))
        XCTAssertFalse(SessionTransfer.isAvailable(for: .fixture(), isOwner: true, machines: [machine("vm")]))
        XCTAssertFalse(SessionTransfer.isAvailable(for: .fixture(kind: .subagent), isOwner: true, machines: both))
        XCTAssertFalse(SessionTransfer.isAvailable(for: .fixture(kind: .supervisor), isOwner: true, machines: both))
        XCTAssertFalse(SessionTransfer.isAvailable(for: .fixture(kind: .ultrafast), isOwner: true, machines: both))
        XCTAssertFalse(
            SessionTransfer.isAvailable(for: .fixture(claudeSessionId: nil), isOwner: true, machines: both))
        XCTAssertFalse(
            SessionTransfer.isAvailable(
                for: .fixture(transferredToSessionId: "s2"), isOwner: true, machines: both))
    }

    func testTargetsAreTheOtherMachinesAndARowWithNoAgentIsTheVMs() {
        XCTAssertEqual(
            SessionTransfer.targets(for: .fixture(agent: "laptop"), machines: both).map(\.slug), ["vm"])
        XCTAssertEqual(
            SessionTransfer.targets(for: .fixture(agent: nil), machines: both).map(\.slug), ["laptop"])
    }

    func testAnOfflineMachineIsListedButNotChoosable() {
        XCTAssertFalse(SessionTransfer.canChoose(machine("laptop", online: false), busy: false))
        XCTAssertFalse(SessionTransfer.canChoose(machine("laptop"), busy: true))
        XCTAssertTrue(SessionTransfer.canChoose(machine("laptop"), busy: false))
    }

    func testLiveMeansAProcessIsRunning() {
        XCTAssertTrue(SessionTransfer.isLive(.fixture(state: .ready)))
        XCTAssertFalse(SessionTransfer.isLive(.fixture(state: .closed)))
        XCTAssertFalse(SessionTransfer.isLive(.fixture(state: nil)))
    }

    func testWordingNamesTheSnapshotOnlyForARunningSession() {
        XCTAssertEqual(SessionTransfer.rowTitle(for: machine("laptop"), live: true), "Copy snapshot to Laptop")
        XCTAssertEqual(SessionTransfer.rowTitle(for: machine("laptop"), live: false), "Transfer to Laptop")
        XCTAssertTrue(SessionTransfer.footer(live: false).contains("transfer it back"))
        XCTAssertFalse(SessionTransfer.footer(live: true).contains("transfer it back"))
    }
}

@MainActor
final class SessionTransferStoreTests: XCTestCase {

    private func makeStore(source: Session) async -> (SessionActionsStore, SessionListStore, FakeSessionActionsApi) {
        let listApi = FakeSessionListApi()
        await listApi.setGetSessionsResult { _ in .success(SessionsPage(sessions: [source], nextCursor: nil)) }
        let list = SessionListStore(api: listApi)
        await list.loadInitialSessions()
        let api = FakeSessionActionsApi()
        return (SessionActionsStore(sessionId: source.id, sessionList: list, api: api), list, api)
    }

    func testAStoppedSessionIsMovedAndTheSourceRowIsMarked() async {
        let (store, list, api) = await makeStore(source: .fixture(id: "s1", state: .closed))
        await api.setTransferResult(
            .success(TransferResponse(snapshot: false, warnings: [], session: .fixture(id: "s2", agent: "vm"))))

        let result = await store.transfer(toAgent: "vm")

        XCTAssertEqual(result?.session.id, "s2")
        let calls = await api.transferCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.force, false)
        XCTAssertNotNil(list.session(withId: "s2"), "the new row has to be in the list to open it")
        XCTAssertEqual(list.session(withId: "s1")?.transferredToSessionId, "s2")
    }

    /// A running session is copied, not moved: it keeps running, so it must stay resumable.
    func testARunningSessionIsSentForcedAndTheSourceIsLeftUnmarked() async {
        let (store, list, api) = await makeStore(source: .fixture(id: "s1", state: .ready))
        await api.setTransferResult(
            .success(TransferResponse(snapshot: true, warnings: ["w"], session: .fixture(id: "s2", agent: "vm"))))

        let result = await store.transfer(toAgent: "vm")

        XCTAssertEqual(result?.warnings, ["w"])
        let calls = await api.transferCalls
        XCTAssertEqual(calls.first?.force, true)
        XCTAssertNil(list.session(withId: "s1")?.transferredToSessionId)
        XCTAssertNotNil(list.session(withId: "s2"))
    }

    func testARefusalKeepsTheServersMessageAndChangesNothing() async {
        let (store, list, api) = await makeStore(source: .fixture(id: "s1", state: .closed))
        await api.setTransferResult(.failure(.detail("The other machine is offline.", statusCode: 409)))

        let result = await store.transfer(toAgent: "vm")

        XCTAssertNil(result)
        XCTAssertEqual(store.errorMessage, "The other machine is offline.")
        XCTAssertNil(list.session(withId: "s1")?.transferredToSessionId)
        XCTAssertNil(list.session(withId: "s2"))
    }
}

extension FakeSessionActionsApi {
    func setTransferResult(_ result: Result<TransferResponse, PaiError>) {
        transferResult = result
    }
}

extension Session {
    fileprivate static func fixture(
        id: String = "s1", state: SessionState? = .ready, kind: SessionKind? = .conversation,
        claudeSessionId: String? = "c1", agent: String? = "vm",
        transferredToSessionId: String? = nil, transferredAt: String? = nil
    ) -> Session {
        Session(
            id: id, sessionType: "claude", status: .active, state: state, blocker: nil, displayState: nil,
            title: nil, titleLocked: nil, initialMessage: nil, sessionTokens: 0, claudeSessionId: claudeSessionId,
            idleTimeoutMinutes: nil, effectiveIdleTimeoutMinutes: nil, cseId: nil, createdAt: nil, updatedAt: nil,
            lastActivityAt: nil, workingDir: nil, agent: agent, kind: kind, parentSessionId: nil,
            subagentName: nil, subagentType: nil, subagentDescription: nil, remoteControl: nil, discovered: nil,
            projectId: nil, phaseId: nil, projectName: nil, transferredToSessionId: transferredToSessionId,
            transferredAt: transferredAt)
    }
}
