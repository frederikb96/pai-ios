import XCTest

@testable import PAIKit

@MainActor
final class TaskEditorStoreTests: XCTestCase {

    private func detail(
        id: String = "t1", gateSource: String? = nil, sessionPolicy: TaskSessionPolicy = .fresh,
        sessionId: String? = nil
    ) -> ScheduledTaskDetail {
        ScheduledTaskDetail(
            id: id, name: "Nightly sweep", enabled: true, environment: "default", workingDir: "/home/frederik",
            prompt: "check things", appendSystemPrompt: nil, cadence: "0 9 * * *", timezone: "UTC",
            hasGate: gateSource != nil, gateRuntime: .bun, gateTimeoutSeconds: 30, sessionPolicy: sessionPolicy,
            sessionId: sessionId, quietPeriodMinutes: 60, supervisionEnabled: false, supervisionModel: nil,
            hasWebhook: false, stopped: false, stoppedReason: nil, lastFireAtMs: nil, lastSuccessAtMs: nil,
            nextFireAtMs: nil, createdAtMs: 0, updatedAtMs: 0, gateSource: gateSource)
    }

    // MARK: - save() dispatches create vs update

    func testSaveCreatesWhenTaskIdIsNil() async {
        let api = FakeTaskEditorApi()
        await api.setCreateResult(.success(detail(id: "new-id")))
        let store = TaskEditorStore(taskId: nil, api: api, timezone: "UTC")
        store.fields.name = "New task"

        let ok = await store.save()

        XCTAssertTrue(ok)
        let creates = await api.createCalls
        XCTAssertEqual(creates.map(\.name), ["New task"])
        let updates = await api.updateCalls
        XCTAssertTrue(updates.isEmpty)
    }

    func testSaveUpdatesTheExistingTaskWhenATaskIdIsGiven() async {
        let api = FakeTaskEditorApi()
        await api.setUpdateResult(.success(detail(id: "t1")))
        let store = TaskEditorStore(taskId: "t1", api: api, timezone: "UTC")

        let ok = await store.save()

        XCTAssertTrue(ok)
        let updates = await api.updateCalls
        XCTAssertEqual(updates.map(\.taskId), ["t1"])
        let creates = await api.createCalls
        XCTAssertTrue(creates.isEmpty)
    }

    // MARK: - the gate checkbox owns gateSource, not the field's own stale text

    /// Unchecking the gate box must send `nil`, not whatever text was left in the field — a task
    /// that once had a gate and had it turned off must not silently keep running the old script.
    func testSavingWithTheGateCheckboxOffSendsNilRegardlessOfStaleFieldText() async {
        let api = FakeTaskEditorApi()
        await api.setCreateResult(.success(detail()))
        let store = TaskEditorStore(taskId: nil, api: api, timezone: "UTC")
        store.setHasGate(true)
        store.fields.gateSource = "exit 0"
        store.setHasGate(false)

        _ = await store.save()

        let creates = await api.createCalls
        XCTAssertNil(creates.first?.gateSource)
    }

    /// Checking the box on with no prior script writes an empty one — never `nil`, since `nil`
    /// there is exactly what "no gate" means.
    func testEnablingTheGateWithNoPriorScriptWritesAnEmptyOne() async {
        let api = FakeTaskEditorApi()
        let store = TaskEditorStore(taskId: nil, api: api, timezone: "UTC")

        store.setHasGate(true)

        XCTAssertEqual(store.fields.gateSource, "")
    }

    // MARK: - promptStaleOnEdit

    func testPromptIsStaleOnlyForAReusingTaskThatHasAlreadyLaunched() async {
        let api = FakeTaskEditorApi()
        await api.setGetResult(.success(detail(sessionPolicy: .reuse, sessionId: "s1")))
        let store = TaskEditorStore(taskId: "t1", api: api, timezone: "UTC")
        await store.load()

        XCTAssertTrue(store.promptStaleOnEdit)
    }

    func testPromptIsNotStaleForAReusingTaskThatHasNeverLaunched() async {
        let api = FakeTaskEditorApi()
        await api.setGetResult(.success(detail(sessionPolicy: .reuse, sessionId: nil)))
        let store = TaskEditorStore(taskId: "t1", api: api, timezone: "UTC")
        await store.load()

        XCTAssertFalse(store.promptStaleOnEdit)
    }

    func testPromptIsNeverStaleForAFreshPolicyEvenWithASession() async {
        let api = FakeTaskEditorApi()
        await api.setGetResult(.success(detail(sessionPolicy: .fresh, sessionId: "s1")))
        let store = TaskEditorStore(taskId: "t1", api: api, timezone: "UTC")
        await store.load()

        XCTAssertFalse(store.promptStaleOnEdit)
    }

    // MARK: - delete / runNow are no-ops while creating

    func testDeleteIsANoOpWithNoTaskIdYet() async {
        let api = FakeTaskEditorApi()
        let store = TaskEditorStore(taskId: nil, api: api, timezone: "UTC")

        let ok = await store.delete()

        XCTAssertFalse(ok)
        let calls = await api.deleteCalls
        XCTAssertTrue(calls.isEmpty)
    }
}
