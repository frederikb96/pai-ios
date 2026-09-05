import XCTest

@testable import PAIKit

@MainActor
final class SchedulerListStoreTests: XCTestCase {

    private func task(id: String) -> ScheduledTask {
        ScheduledTask(
            id: id, name: "Task \(id)", enabled: true, environment: "default", workingDir: nil, prompt: "p",
            appendSystemPrompt: nil, cadence: nil, timezone: "UTC", hasGate: false, gateRuntime: nil,
            gateTimeoutSeconds: 30, sessionPolicy: .fresh, sessionId: nil, quietPeriodMinutes: 60,
            supervisionEnabled: false, supervisionModel: nil, hasWebhook: false, stopped: false,
            stoppedReason: nil, lastFireAtMs: nil, lastSuccessAtMs: nil, nextFireAtMs: nil, createdAtMs: 0,
            updatedAtMs: 0)
    }

    func testLoadPopulatesTasksFromTheServer() async {
        let api = FakeSchedulerListApi()
        await api.setResult(
            .success(SchedulerTaskListResponse(tasks: [task(id: "t1"), task(id: "t2")], nextOffset: nil)))
        let store = SchedulerListStore(api: api)

        await store.load()

        XCTAssertEqual(store.tasks.map(\.id), ["t1", "t2"])
        XCTAssertNil(store.errorMessage)
    }

    func testLoadFailureSurfacesAsAnErrorMessageRatherThanCrashing() async {
        let api = FakeSchedulerListApi()
        await api.setResult(.failure(.detail("could not reach the server", statusCode: 500)))
        let store = SchedulerListStore(api: api)

        await store.load()

        XCTAssertEqual(store.errorMessage, "could not reach the server")
        XCTAssertTrue(store.tasks.isEmpty)
    }
}
