import XCTest

@testable import PAIKit

/// The header's model switch crosses four hand-threaded places (`Session`, the status event,
/// `TranscriptStore.LiveSessionStatus`, `SessionListStore.applyLiveStatus`); each test here
/// follows a value across one of those seams, because a miss at any of them leaves the model row
/// right and the live stream silent.
@MainActor
final class SessionModelSwitchTests: XCTestCase {

    override func tearDown() {
        PaiStubURLProtocol.reset()
        super.tearDown()
    }

    private func status(_ json: String) throws -> SseStatusEvent {
        try JSONDecoder().decode(SseStatusEvent.self, from: Data(json.utf8))
    }

    private func live(_ json: String) throws -> TranscriptStore.LiveSessionStatus {
        let store = TranscriptStore()
        store.applySseStatus(sessionId: "s1", event: try status(json))
        return try XCTUnwrap(store.liveStatus["s1"])
    }

    // MARK: - Wire

    func testSessionDecodesPendingModelFromTheWire() async throws {
        let json = Data(
            """
            {"id":"s1","session_type":"home","status":"active","state":null,"blocker":null,
             "title":null,"title_locked":null,"initial_message":null,"session_tokens":0,
             "claude_session_id":null,"cse_id":null,"created_at":null,"updated_at":null,
             "last_activity_at":null,"working_dir":null,"model":"opus","pending_model":"sonnet"}
            """.utf8)
        let session = try JSONDecoder().decode(Session.self, from: json)
        XCTAssertEqual(session.model, "opus")
        XCTAssertEqual(session.pendingModel, "sonnet")
    }

    func testStatusEventCarriesModelAndPendingModelIntoLiveStatus() async throws {
        let status = try live(
            #"{"status":"active","state":null,"blocker":null,"model":"opus","pending_model":"sonnet"}"#)
        XCTAssertEqual(status.model, "opus")
        XCTAssertEqual(status.pendingModel, "sonnet")
    }

    // MARK: - Rebuilds

    /// `withLiveStatus` replaces the pending switch outright — the event's `null` is "nothing
    /// waiting" — but merges `model`, so a backend that omits it leaves the polled alias alone.
    func testWithLiveStatusReplacesPendingAndMergesModel() async {
        let session = SessionFixture.make(model: "opus", pendingModel: "sonnet")
        let cleared = session.withLiveStatus(
            state: nil, blocker: nil, turnState: nil, displayState: nil, activityCounts: nil,
            secretGrantable: nil, secretPrompt: nil, liveModel: nil, model: nil, pendingModel: nil)
        XCTAssertNil(cleared.pendingModel)
        XCTAssertEqual(cleared.model, "opus")

        let switched = cleared.withLiveStatus(
            state: nil, blocker: nil, turnState: nil, displayState: nil, activityCounts: nil,
            secretGrantable: nil, secretPrompt: nil, liveModel: nil, model: "haiku", pendingModel: "haiku")
        XCTAssertEqual(switched.model, "haiku")
        XCTAssertEqual(switched.pendingModel, "haiku")
    }

    func testPendingModelSurvivesPinAndActivityRebuilds() async {
        let session = SessionFixture.make(model: "opus", pendingModel: "sonnet")
        XCTAssertEqual(session.withPinnedAt("2026-01-01T00:00:00Z").pendingModel, "sonnet")
        XCTAssertEqual(session.withLastActivityAt("2026-01-02T00:00:00Z").pendingModel, "sonnet")
    }

    func testListStoreRoutesTheStatusEventsSwitchIntoTheRow() async {
        let api = FakeSessionListApi()
        await api.setGetSessionsResult { _ in
            .success(SessionsPage(sessions: [SessionFixture.make(id: "s1", model: "opus")], nextCursor: nil))
        }
        let store = SessionListStore(api: api, debounceNanos: 20_000_000)
        await store.loadInitialSessions()

        store.applyLiveStatus(
            sessionId: "s1", state: nil, blocker: nil, turnState: nil, displayState: nil,
            activityCounts: nil, secretGrantable: nil, secretPrompt: nil, liveModel: nil,
            model: "sonnet", pendingModel: "sonnet")

        XCTAssertEqual(store.syncedSessions.first?.model, "sonnet")
        XCTAssertEqual(store.syncedSessions.first?.pendingModel, "sonnet")
    }

    // MARK: - Badge

    func testBadgeShowsAPendingSwitchOverTheLiveModel() async throws {
        let session = SessionFixture.make(liveModel: "claude-opus-4-8", model: "opus")
        let pending = try live(
            #"{"status":"active","state":null,"blocker":null,"live_model":"claude-opus-4-8","model":"sonnet","pending_model":"sonnet"}"#
        )
        XCTAssertEqual(SessionModelSwitch.badgeLabel(session, live: pending), "Sonnet")

        // The first reply from the new family clears the switch; the exact model takes over.
        let answered = try live(
            #"{"status":"active","state":null,"blocker":null,"live_model":"claude-sonnet-5","model":"sonnet","pending_model":null}"#
        )
        XCTAssertEqual(SessionModelSwitch.badgeLabel(session, live: answered), "Sonnet 5")
    }

    /// The live stream's `null` pending is an answer, so a stale pending on the polled row must not
    /// bring the switch back.
    func testLiveStreamsNilPendingBeatsAStalePolledOne() async throws {
        let session = SessionFixture.make(liveModel: "claude-sonnet-5", model: "sonnet", pendingModel: "haiku")
        let answered = try live(
            #"{"status":"active","state":null,"blocker":null,"live_model":"claude-sonnet-5","pending_model":null}"#)
        XCTAssertEqual(SessionModelSwitch.badgeLabel(session, live: answered), "Sonnet 5")
        XCTAssertEqual(SessionModelSwitch.badgeLabel(session, live: nil), "Haiku")
    }

    func testBadgeFallsBackToTheLaunchAliasThenDefault() async {
        XCTAssertEqual(SessionModelSwitch.badgeLabel(SessionFixture.make(model: "fable"), live: nil), "Fable")
        XCTAssertEqual(SessionModelSwitch.badgeLabel(SessionFixture.make(), live: nil), "Default")
        // Not switchable and nothing to say: the quiet badge stays absent.
        XCTAssertNil(SessionModelSwitch.badgeLabel(SessionFixture.make(kind: .subagent), live: nil))
    }

    func testOnlySessionsWithAProcessCanSwitch() async {
        XCTAssertTrue(SessionModelSwitch.canSwitch(SessionFixture.make(kind: .conversation)))
        for kind in [SessionKind.subagent, .supervisor, .computer, .ultrafast] {
            XCTAssertFalse(SessionModelSwitch.canSwitch(SessionFixture.make(kind: kind)), "\(kind)")
        }
    }

    func testCurrentAliasPrefersPendingThenLiveStreamThenRow() async throws {
        let session = SessionFixture.make(model: "opus", pendingModel: "haiku")
        XCTAssertEqual(SessionModelSwitch.currentAlias(session, live: nil), "haiku")
        let settled = try live(#"{"status":"active","state":null,"blocker":null,"model":"sonnet"}"#)
        XCTAssertEqual(SessionModelSwitch.currentAlias(session, live: settled), "sonnet")
    }

    // MARK: - Folder

    func testFolderNameIsTheLastSegment() async {
        XCTAssertEqual(WorkingFolder.name(of: "/home/frederik/Programming/pai-cloud"), "pai-cloud")
        XCTAssertEqual(WorkingFolder.name(of: "/home/frederik/Programming/pai-cloud///"), "pai-cloud")
        XCTAssertEqual(WorkingFolder.name(of: "/"), "/")
        XCTAssertEqual(WorkingFolder.name(of: "relative"), "relative")
    }

    // MARK: - API and store

    private func makeClient() throws -> PaiApiClient {
        let factory = try PaiRequestFactory(baseURL: "https://pai.example.com", tokenProvider: { "jwt" })
        return PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
    }

    func testSetSessionModelPostsTheAliasAndDecodesApplied() async throws {
        PaiStubURLProtocol.stub = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"sonnet","applied":"next_launch"}"#.utf8))
        let result = try await makeClient().setSessionModel(sessionId: "s1", model: "sonnet")

        let request = try XCTUnwrap(PaiStubURLProtocol.capturedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/session/s1/model")
        let body = try XCTUnwrap(PaiStubURLProtocol.capturedBody)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: body), ["model": "sonnet"])
        XCTAssertEqual(result, SetSessionModelResponse(model: "sonnet", applied: .nextLaunch))
    }

    func testUnknownAppliedValueDecodesInsteadOfThrowing() async throws {
        let result = try JSONDecoder().decode(
            SetSessionModelResponse.self, from: Data(#"{"model":"opus","applied":"later"}"#.utf8))
        XCTAssertEqual(result.applied, .unrecognized("later"))
    }

    func testStoreSendsNothingForTheModelAlreadyInForce() async {
        let api = FakeSessionModelApi()
        let store = SessionModelSwitchStore(sessionId: "s1", api: api)
        let outcome = await store.choose("opus", current: "opus")
        let calls = await api.setCalls
        XCTAssertEqual(outcome, .unchanged)
        XCTAssertTrue(calls.isEmpty)
    }

    func testStoreReportsNextLaunchAndRefusals() async {
        let api = FakeSessionModelApi()
        let store = SessionModelSwitchStore(sessionId: "s1", api: api)

        await api.setResult(.success(SetSessionModelResponse(model: "sonnet", applied: .now)))
        let now = await store.choose("sonnet", current: "opus")
        XCTAssertEqual(now, .switched)

        await api.setResult(.success(SetSessionModelResponse(model: "haiku", applied: .nextLaunch)))
        let later = await store.choose("haiku", current: "opus")
        XCTAssertEqual(later, .nextLaunch(message: "Haiku from the session's next start"))

        await api.setResult(.failure(.detail("the process refused", statusCode: 502)))
        let refused = await store.choose("fable", current: "opus")
        XCTAssertEqual(refused, .failed)
        XCTAssertEqual(store.errorMessage, "Couldn't switch the model: the process refused")
        let calls = await api.setCalls
        XCTAssertEqual(calls.map(\.model), ["sonnet", "haiku", "fable"])
        XCTAssertEqual(calls.map(\.sessionId), ["s1", "s1", "s1"])
    }
}

actor FakeSessionModelApi: SessionModelApiClient {
    private(set) var setCalls: [(sessionId: String, model: String)] = []
    var result: Result<SetSessionModelResponse, PaiError> = .success(
        SetSessionModelResponse(model: "opus", applied: .now))

    func setResult(_ result: Result<SetSessionModelResponse, PaiError>) { self.result = result }

    func getSessionModels() async throws -> SessionModelsResponse {
        SessionModelsResponse(models: [], fastDefaultModel: "sonnet", fastDefaultThinking: "low")
    }

    func setSessionModel(sessionId: String, model: String) async throws -> SetSessionModelResponse {
        setCalls.append((sessionId, model))
        return try result.get()
    }
}
