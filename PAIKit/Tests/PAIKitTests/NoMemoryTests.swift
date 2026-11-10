import XCTest

@testable import PAIKit

/// The no-memory switch: the field on every wire shape that carries it, the launch choice that
/// sends it, and the two session-menu entries that depend on it.
@MainActor
final class NoMemoryTests: XCTestCase {
    private func makeClient() throws -> PaiApiClient {
        let factory = try PaiRequestFactory(baseURL: "https://pai.example.com", tokenProvider: { "jwt" })
        return PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
    }

    private func makeCreateStore() -> CreateSessionStore {
        CreateSessionStore(machines: MachineStore(api: FakeMachineDirectoryApi()), api: FakeCreateSessionApi())
    }

    // MARK: - Wire

    func testAStatusEventCarriesTheFlagIntoTheLiveStatusAndTheRow() async throws {
        let json = #"{"status":"active","state":"ready","blocker":null,"no_memory":true}"#
        let event = try JSONDecoder().decode(SseStatusEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.noMemory, true)

        let transcript = TranscriptStore()
        transcript.applySseStatus(sessionId: "s1", event: event)
        XCTAssertEqual(transcript.liveStatus["s1"]?.noMemory, true)

        let row = SessionFixture.make().withLiveStatus(
            state: .ready, blocker: nil, turnState: nil, displayState: nil, activityCounts: nil,
            secretGrantable: nil, secretPrompt: nil, liveModel: nil, model: nil, pendingModel: nil,
            noMemory: true)
        XCTAssertTrue(row.isNoMemory)
    }

    func testALiveStatusWithoutTheFlagKeepsTheRowsOwn() async {
        let row = SessionFixture.make(noMemory: true).withLiveStatus(
            state: .ready, blocker: nil, turnState: nil, displayState: nil, activityCounts: nil,
            secretGrantable: nil, secretPrompt: nil, liveModel: nil, model: nil, pendingModel: nil)
        XCTAssertTrue(row.isNoMemory)
    }

    func testEveryCopyOfARowKeepsTheFlag() async {
        let row = SessionFixture.make(noMemory: true)
        XCTAssertTrue(row.withPinnedAt("2026-01-01T00:00:00Z").isNoMemory)
        XCTAssertTrue(row.withLastActivityAt("2026-01-01T00:00:00Z").isNoMemory)
    }

    func testAnAbsentFlagReadsAsAnOrdinarySession() async throws {
        XCTAssertFalse(SessionFixture.make().isNoMemory)
        let draft = try JSONDecoder().decode(
            Draft.self, from: Data(#"{"key":"new","text":"","version":1,"attachments":[]}"#.utf8))
        XCTAssertNil(draft.noMemory)
    }

    func testTheCreateRequestNamesTheFlagOnlyWhenOn() async throws {
        PaiStubURLProtocol.stub = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"],
            body: Data(#"{"session_id":"s1","message_id":1,"duplicate":false,"draft_version":1}"#.utf8))
        let client = try makeClient()
        _ = try await client.postMessage(message: "hi", sessionType: "home", noMemory: true)
        let on = String(decoding: try XCTUnwrap(PaiStubURLProtocol.capturedBody), as: UTF8.self)
        XCTAssertTrue(on.contains("name=\"no_memory\"\r\n\r\ntrue"))

        _ = try await client.postMessage(message: "hi", sessionType: "home")
        let off = String(decoding: try XCTUnwrap(PaiStubURLProtocol.capturedBody), as: UTF8.self)
        XCTAssertFalse(off.contains("no_memory"))
    }

    func testTheDraftWriteCarriesTheFlag() async throws {
        PaiStubURLProtocol.stub = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"],
            body: Data(#"{"key":"new","version":2,"previous_text":null}"#.utf8))
        let client = try makeClient()
        _ = try await client.putDraft(key: "new", text: "", noMemory: true)
        let sent = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(PaiStubURLProtocol.capturedBody)) as? [String: Any])
        XCTAssertEqual(sent["no_memory"] as? Bool, true)
    }

    // MARK: - Launch choice

    func testTheSwitchIsIndependentOfTheModelChoice() async {
        let store = makeCreateStore()
        store.selectNoMemory(true)
        store.selectModel("opus")
        store.selectThinking("high")
        XCTAssertTrue(store.noMemory)
        store.selectModel("sonnet")
        XCTAssertTrue(store.noMemory, "picking another model must leave the switch alone")
    }

    func testTheFirstMessageGoesOutWithTheFlagOnlyWhenOn() async {
        let sending = FakeOutboxSending()
        let outbox = OutboxStore(api: sending, storage: OutboxInMemoryStorage())
        let store = makeCreateStore()
        store.selectNoMemory(true)
        store.enqueueSend(message: "secret chat", outbox: outbox)

        let deadline = Date().addingTimeInterval(2)
        while await sending.postMessageCalls.isEmpty, Date() < deadline { await Task.yield() }
        let calls = await sending.postMessageCalls
        XCTAssertEqual(calls.first?.noMemory, true)

        let ordinary = makeCreateStore()
        let second = FakeOutboxSending()
        let secondOutbox = OutboxStore(api: second, storage: OutboxInMemoryStorage())
        ordinary.enqueueSend(message: "hi", outbox: secondOutbox)
        let secondDeadline = Date().addingTimeInterval(2)
        while await second.postMessageCalls.isEmpty, Date() < secondDeadline { await Task.yield() }
        let secondCalls = await second.postMessageCalls
        XCTAssertNil(secondCalls.first?.noMemory)
    }

    func testTurningItOnDropsAHermesModelAndDisablesHermesEntries() async {
        let api = FakeCreateSessionApi()
        await api.setSessionModelsResult(
            .success(
                SessionModelsResponse(
                    models: [
                        SessionModelInfo(id: "opus", effortLevels: ["low"]),
                        SessionModelInfo(id: "hermes:sva", effortLevels: [], engine: "hermes"),
                    ], fastDefaultModel: "sonnet", fastDefaultThinking: "low")))
        let store = CreateSessionStore(machines: MachineStore(api: FakeMachineDirectoryApi()), api: api)
        await store.start()
        store.selectSessionType("home")
        XCTAssertTrue(store.pickerModels.contains { $0.isHermes })
        store.selectModel("hermes:sva")

        store.selectNoMemory(true)

        XCTAssertNil(store.selectedModel)
        let hermes = store.pickerModels.filter(\.isHermes)
        XCTAssertFalse(hermes.isEmpty, "Hermes entries stay listed")
        XCTAssertTrue(hermes.allSatisfy(store.isModelDisabled))
        XCTAssertFalse(store.pickerModels.filter { !$0.isHermes }.contains(where: store.isModelDisabled))
    }

    func testAFreshVisitStartsWithTheSwitchOff() async {
        let store = makeCreateStore()
        store.selectNoMemory(true)
        store.reset()
        XCTAssertFalse(store.noMemory)
    }

    // MARK: - Session menu

    func testCompactAndCloseIsOfferedOnlyForALiveClaudeConversation() async {
        XCTAssertTrue(SessionCompactAndClose.isAvailable(for: SessionFixture.make(state: .ready)))
        XCTAssertFalse(SessionCompactAndClose.isAvailable(for: SessionFixture.make(state: .closed)))
        XCTAssertFalse(SessionCompactAndClose.isAvailable(for: SessionFixture.make(state: nil)))
        XCTAssertFalse(SessionCompactAndClose.isAvailable(for: SessionFixture.make(state: .ready, noMemory: true)))
        XCTAssertFalse(
            SessionCompactAndClose.isAvailable(for: SessionFixture.make(state: .ready, kind: .ultrafast)))
        XCTAssertFalse(
            SessionCompactAndClose.isAvailable(for: SessionFixture.make(state: .ready, model: "hermes:sva")))
    }

    func testANoMemorySessionCannotBeTransferred() async {
        let machines = [
            Machine(
                slug: "vm", displayName: "vm", online: true, lastSeenAt: nil, ingestEnabled: true,
                capabilities: .init(fastSessions: true, reboot: true, shell: true, rcLocal: true), sessionTypes: []),
            Machine(
                slug: "laptop", displayName: "laptop", online: true, lastSeenAt: nil, ingestEnabled: true,
                capabilities: .init(fastSessions: true, reboot: true, shell: true, rcLocal: true), sessionTypes: []),
        ]
        let ordinary = SessionFixture.make(claudeSessionId: "c1")
        let noMemory = SessionFixture.make(claudeSessionId: "c1", noMemory: true)
        XCTAssertTrue(SessionTransfer.isAvailable(for: ordinary, isOwner: true, machines: machines))
        XCTAssertFalse(SessionTransfer.isAvailable(for: noMemory, isOwner: true, machines: machines))
    }

    func testCompactAndCloseCallsItsRouteAndAFailureIsAToastWithRetry() async {
        let listApi = FakeSessionListApi()
        await listApi.setGetSessionsResult { _ in
            .success(SessionsPage(sessions: [SessionFixture.make(id: "s1")], nextCursor: nil))
        }
        let list = SessionListStore(api: listApi)
        await list.loadInitialSessions()
        let actionsApi = FakeSessionActionsApi()
        let store = SessionActionsStore(sessionId: "s1", sessionList: list, api: actionsApi)
        let toasts = ToastCenter()

        store.compactAndCloseInBackground(toasts: toasts)
        var deadline = ContinuousClock().now + .seconds(5)
        while await actionsApi.compactAndCloseCalls.isEmpty, ContinuousClock().now < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let calls = await actionsApi.compactAndCloseCalls
        XCTAssertEqual(calls, ["s1"])
        deadline = ContinuousClock().now + .seconds(5)
        while toasts.toasts.isEmpty, ContinuousClock().now < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(toasts.toasts.first?.text, SessionCompactAndClose.compactingToast)
        XCTAssertEqual(toasts.toasts.first?.kind, .info)
        if let id = toasts.toasts.first?.id { toasts.dismiss(id) }

        await actionsApi.setCompactAndCloseError(.transport("down"))
        store.compactAndCloseInBackground(toasts: toasts)
        deadline = ContinuousClock().now + .seconds(5)
        while toasts.toasts.isEmpty, ContinuousClock().now < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(toasts.toasts.first?.kind, .error)
        XCTAssertNotNil(toasts.toasts.first?.action)
    }
}
