import XCTest

@testable import PAIKit

@MainActor
final class SchedulerListStoreTests: XCTestCase {

    private func task(id: String) -> ScheduledTask {
        ScheduledTask(
            id: id, name: "Task \(id)", enabled: true, environment: "home", workingDir: nil, prompt: "p",
            appendSystemPrompt: nil, cadence: nil, timezone: "UTC", hasGate: false, gateRuntime: nil,
            gateTimeoutSeconds: 30, sessionPolicy: .fresh, sessionId: nil, quietPeriodMinutes: 60,
            supervisionEnabled: false, supervisionModel: nil, stopped: false,
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

    private func wake(id: String) -> InboxWake {
        InboxWake(
            id: id, sessionId: "s-\(id)", sessionTitle: "Session \(id)", inbox: "github",
            subjectPattern: "Issue", senderPattern: nil, prompt: "Look", debounceMinutes: 30,
            pendingCount: 0, dueAt: nil, deliveredThrough: "2026-11-09T08:00:00+00:00",
            lastWokenAt: nil, createdAt: "2026-11-08T08:00:00+00:00")
    }

    func testRemovingAWakeDropsItOnlyWhenTheServerRemovedIt() async {
        let api = FakeSchedulerListApi()
        await api.setWakes([wake(id: "w1"), wake(id: "w2")])
        let store = SchedulerListStore(api: api)
        await store.loadWakes()

        await store.removeWake(id: "w1")
        XCTAssertEqual(store.wakes.map(\.id), ["w2"])

        // A refusal keeps the registration and says so.
        await api.setDeleteResult(.failure(.detail("No inbox wake w2", statusCode: 404)))
        await store.removeWake(id: "w2")
        XCTAssertEqual(store.wakeErrorMessage, "No inbox wake w2")
        XCTAssertEqual(store.wakes.map(\.id), ["w2"])
    }
}
