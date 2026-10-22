import Foundation
import XCTest

@testable import PAIKit

private actor FakePushChannelsApi: PushChannelsApiClient {
    var response: Result<PushChannelsResponse, PaiError> = .success(PushChannelsResponse(channels: []))
    private(set) var calls = 0

    func setResponse(_ response: Result<PushChannelsResponse, PaiError>) { self.response = response }

    func getPushChannels() async throws -> PushChannelsResponse {
        calls += 1
        return try response.get()
    }
}

@MainActor
final class PushChannelsStoreTests: XCTestCase {

    private let served = [
        PushChannelInfo(id: "default", label: "Agent messages", description: "d1", kinds: ["agent"]),
        PushChannelInfo(id: "alerts", label: "Alerts", description: "d2", kinds: ["alert"]),
    ]

    func testSwitchesAreTheServedChannelsInTheServersOrder() async {
        let api = FakePushChannelsApi()
        await api.setResponse(.success(PushChannelsResponse(channels: served)))
        let store = PushChannelsStore(api: api)

        await store.load()

        XCTAssertEqual(store.rows(muted: []).map(\.label), ["Agent messages", "Alerts"])
        XCTAssertEqual(store.offeredIds, ["default", "alerts"])
    }

    /// A mute this device holds for a channel the server no longer lists must stay reachable, or
    /// the registration carries it for good with no switch to undo it.
    func testAMutedIdTheServerDoesNotListStaysAsASwitch() async {
        let api = FakePushChannelsApi()
        await api.setResponse(.success(PushChannelsResponse(channels: served)))
        let store = PushChannelsStore(api: api)
        await store.load()

        let rows = store.rows(muted: ["alerts", "digest"])

        XCTAssertEqual(rows.map(\.id), ["default", "alerts", "digest"])
        XCTAssertEqual(rows.last?.label, "digest")
    }

    /// Before the list has loaded nothing is known, so no switch is invented from the mutes alone.
    func testNothingIsInventedBeforeTheListLoads() {
        let store = PushChannelsStore(api: FakePushChannelsApi())
        XCTAssertEqual(store.rows(muted: ["digest"]), [])
    }

    func testAFailedLoadIsRetriedAndASuccessfulOneIsNot() async {
        let api = FakePushChannelsApi()
        await api.setResponse(.failure(.transport("offline")))
        let store = PushChannelsStore(api: api)

        await store.load()
        XCTAssertNil(store.channels)

        await api.setResponse(.success(PushChannelsResponse(channels: served)))
        await store.load()
        await store.load()

        XCTAssertEqual(store.channels, served)
        let calls = await api.calls
        XCTAssertEqual(calls, 2)
    }
}

private actor FakeAlertRoutingApi: AlertRoutingApiClient {
    var current: AlertRoutingSettings
    private(set) var updates: [AlertRoutingUpdate] = []
    var tasks: [ScheduledTask] = []

    init(
        routes: [String: AlertRoute] = [:], taskId: String? = nil, problem: String? = nil,
        kindTasks: [String: String] = [:], kindProblems: [String: String] = [:]
    ) {
        current = AlertRoutingSettings(
            kinds: [
                AlertKindInfo(id: "relay", label: "Relayed reports", patterns: ["relay:*"]),
                AlertKindInfo(id: "other", label: "Other", patterns: []),
            ], routes: routes, agentTaskId: taskId, agentTaskName: nil, agentTaskProblem: problem,
            kindTasks: kindTasks, kindTaskProblems: kindProblems, updatedAt: "2026-10-12T00:00:00Z")
    }

    func getAlertRouting() async throws -> AlertRoutingSettings { current }

    func updateAlertRouting(_ update: AlertRoutingUpdate) async throws -> AlertRoutingSettings {
        updates.append(update)
        current = AlertRoutingSettings(
            kinds: current.kinds, routes: update.routes, agentTaskId: update.agentTaskId,
            agentTaskName: nil, agentTaskProblem: current.agentTaskProblem, kindTasks: update.kindTasks,
            kindTaskProblems: current.kindTaskProblems, updatedAt: current.updatedAt)
        return current
    }

    func listSchedulerTasks(limit: Int?, offset: Int?) async throws -> SchedulerTaskListResponse {
        throw PaiError.transport("offline")
    }
}

@MainActor
final class AlertRoutingStoreTests: XCTestCase {

    /// `notify` is the default and is never stored: leaving an explicit entry behind would make a
    /// kind that was set back to "Me" still count as routed.
    func testRoutingBackToMeRemovesTheEntryAndKeepsTheOthers() async {
        let api = FakeAlertRoutingApi(routes: ["relay": .both, "other": .agent], taskId: "t1")
        let store = AlertRoutingStore(api: api)
        await store.load()

        await store.setRoute(.notify, forKind: "relay")

        let updates = await api.updates
        XCTAssertEqual(updates, [AlertRoutingUpdate(routes: ["other": .agent], agentTaskId: "t1", kindTasks: [:])])
        XCTAssertEqual(store.route(forKind: "relay"), .notify)
    }

    /// Choosing a task must write the whole map back: the server resets every kind a partial
    /// write leaves out.
    func testChoosingATaskWritesTheWholeMapBack() async {
        let api = FakeAlertRoutingApi(routes: ["relay": .agent])
        let store = AlertRoutingStore(api: api)
        await store.load()

        await store.setAgentTask(id: "t9")

        let updates = await api.updates
        XCTAssertEqual(updates, [AlertRoutingUpdate(routes: ["relay": .agent], agentTaskId: "t9", kindTasks: [:])])
    }

    func testTheClearedTaskIsWrittenAsAnExplicitNull() throws {
        let body = try JSONEncoder().encode(AlertRoutingUpdate(routes: [:], agentTaskId: nil, kindTasks: [:]))
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains(#""agent_task_id":null"#), text)
        // Omitted, the server keeps the stored per-kind tasks; `{}` is how they are cleared.
        XCTAssertTrue(text.contains(#""kind_tasks":{}"#), text)
    }

    /// The task is written beside the whole map, and every other write carries the stored
    /// per-kind tasks along instead of resetting them.
    func testAKindTaskIsSetClearedAndCarriedThroughOtherWrites() async {
        let api = FakeAlertRoutingApi(routes: ["relay": .agent, "other": .both], kindTasks: ["other": "t3"])
        let store = AlertRoutingStore(api: api)
        await store.load()

        await store.setTask(id: "t7", forKind: "relay")
        await store.setRoute(.notify, forKind: "other")
        await store.setTask(id: nil, forKind: "relay")

        let updates = await api.updates
        XCTAssertEqual(
            updates,
            [
                AlertRoutingUpdate(
                    routes: ["relay": .agent, "other": .both], agentTaskId: nil,
                    kindTasks: ["relay": "t7", "other": "t3"]),
                AlertRoutingUpdate(
                    routes: ["relay": .agent], agentTaskId: nil, kindTasks: ["relay": "t7", "other": "t3"]),
                AlertRoutingUpdate(
                    routes: ["relay": .agent], agentTaskId: nil, kindTasks: ["other": "t3"]),
            ])
    }

    /// The default task's problem only matters to a kind that depends on it.
    func testTheDefaultTaskProblemIgnoresKindsWithATaskOfTheirOwn() async {
        let own = AlertRoutingStore(
            api: FakeAlertRoutingApi(
                routes: ["relay": .agent], problem: "the task is disabled", kindTasks: ["relay": "t2"]))
        await own.load()
        XCTAssertNil(own.agentProblem)

        let mixed = AlertRoutingStore(
            api: FakeAlertRoutingApi(
                routes: ["relay": .agent, "other": .both], problem: "the task is disabled",
                kindTasks: ["relay": "t2"]))
        await mixed.load()
        XCTAssertEqual(mixed.agentProblem, "the task is disabled")
    }

    func testAKindTaskProblemIsLookedUpPerKind() async {
        let store = AlertRoutingStore(
            api: FakeAlertRoutingApi(
                routes: ["relay": .agent], kindTasks: ["relay": "t2"], kindProblems: ["relay": "it is stopped"]))
        await store.load()
        XCTAssertEqual(store.problem(forKind: "relay"), "it is stopped")
        XCTAssertNil(store.problem(forKind: "other"))
    }

    /// The server's explanation is only relevant once something is actually routed to the agent.
    func testTheTaskProblemShowsOnlyWhileSomethingIsRoutedToTheAgent() async {
        let quiet = AlertRoutingStore(api: FakeAlertRoutingApi(problem: "the task is disabled"))
        await quiet.load()
        XCTAssertNil(quiet.agentProblem)

        let routed = AlertRoutingStore(
            api: FakeAlertRoutingApi(routes: ["relay": .agent], problem: "the task is disabled"))
        await routed.load()
        XCTAssertEqual(routed.agentProblem, "the task is disabled")
    }

    func testTheRowSummaryCountsKindsRoutedAwayFromMe() async {
        let none = AlertRoutingStore(api: FakeAlertRoutingApi())
        await none.load()
        XCTAssertEqual(none.summary, "All to you")

        let three = AlertRoutingStore(
            api: FakeAlertRoutingApi(routes: ["a": .agent, "b": .both, "c": .agent]))
        await three.load()
        XCTAssertEqual(three.summary, "3 kinds routed")
    }

    /// A route value this build does not know decodes and survives a write-back instead of
    /// failing the screen or being rewritten to something else.
    func testAnUnknownRouteValueRoundTrips() throws {
        let json = Data(
            #"{"kinds":[],"routes":{"x":"escalate"},"agent_task_id":null,"agent_task_name":null,"agent_task_problem":null,"kind_tasks":{},"kind_task_problems":{},"updated_at":"t"}"#
                .utf8)
        let settings = try JSONDecoder().decode(AlertRoutingSettings.self, from: json)
        XCTAssertEqual(settings.routes["x"], .unrecognized("escalate"))
        let body = try JSONEncoder().encode(
            AlertRoutingUpdate(routes: settings.routes, agentTaskId: nil, kindTasks: [:]))
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains(#""x":"escalate""#))
    }
}

final class NotificationSettingsWireTests: XCTestCase {

    override func tearDown() {
        PaiStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() throws -> PaiApiClient {
        let factory = try PaiRequestFactory(baseURL: "https://pai.example.com", tokenProvider: { "jwt" })
        return PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
    }

    private func stub(_ json: String) {
        PaiStubURLProtocol.stub = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
    }

    func testPushChannelsDecodeWithTheirKinds() async throws {
        stub(
            #"{"channels":[{"id":"default","label":"Agent messages","description":"d","kinds":["agent"]}]}"#)
        let response = try await makeClient().getPushChannels()

        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.url?.path, "/api/push/channels")
        XCTAssertEqual(response.channels.first?.id, "default")
        XCTAssertEqual(response.channels.first?.kinds, ["agent"])
    }

    /// The muted list is sent even when empty, ids unchanged: an absent field would leave a
    /// cleared last mute in place on the server.
    func testRegisteringSendsTheMutedIdsAsGiven() async throws {
        stub(#"{"token":"abc","registered":true,"last_seen_at":null,"muted_channels":["digest"]}"#)
        let result = try await makeClient().registerDevice(token: "abc", mutedChannels: ["digest"])

        let body = String(data: PaiStubURLProtocol.capturedBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains(#""muted_channels":["digest"]"#), body)
        XCTAssertEqual(result.mutedChannels, ["digest"])

        stub(#"{"token":"abc","registered":true,"last_seen_at":null,"muted_channels":[]}"#)
        _ = try await makeClient().registerDevice(token: "abc", mutedChannels: [])
        let empty = String(data: PaiStubURLProtocol.capturedBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(empty.contains(#""muted_channels":[]"#), empty)
    }

    func testAlertRoutingIsReadAndWrittenAtItsSettingsRoute() async throws {
        stub(
            #"{"kinds":[{"id":"other","label":"Other","patterns":[]}],"routes":{},"agent_task_id":null,"agent_task_name":null,"agent_task_problem":null,"kind_tasks":{"other":"t5"},"kind_task_problems":{"other":"gone"},"updated_at":"t"}"#
        )
        let client = try makeClient()
        let settings = try await client.getAlertRouting()
        XCTAssertEqual(settings.kindTasks, ["other": "t5"])
        XCTAssertEqual(settings.kindTaskProblems, ["other": "gone"])
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.url?.path, "/api/settings/alert-routing")
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.httpMethod, "GET")

        _ = try await client.updateAlertRouting(
            AlertRoutingUpdate(routes: ["other": .both], agentTaskId: "t1", kindTasks: ["other": "t5"]))
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.httpMethod, "PUT")
        let body = String(data: PaiStubURLProtocol.capturedBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains(#""other":"both""#), body)
        XCTAssertTrue(body.contains(#""agent_task_id":"t1""#), body)
        XCTAssertTrue(body.contains(#""kind_tasks":{"other":"t5"}"#), body)
    }
}
