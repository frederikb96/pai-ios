import XCTest

@testable import PAIKit

/// A task that fires once at `run_at` instead of on a cadence: the field on the wire, the label the
/// list shows, and what the editor sends for each way a task can be due.
@MainActor
final class SchedulerRunAtTests: XCTestCase {

    /// The backend writes the instant with Python's `isoformat()`: a numeric offset, and six
    /// fractional digits whenever the stored value carries any.
    private func taskJSON(runAt: String?, cadence: String? = nil, policy: String = "fresh") -> Data {
        let runAtField = runAt.map { "\"run_at\":\"\($0)\"," } ?? ""
        let cadenceField = cadence.map { "\"\($0)\"" } ?? "null"
        let json = """
            {"id":"t1","name":"s-recheck","enabled":true,"environment":"home","working_dir":null,
             "prompt":"look again","append_system_prompt":null,"cadence":\(cadenceField),\(runAtField)
             "timezone":"Europe/Berlin","has_gate":false,"gate_runtime":null,"gate_timeout_seconds":120,
             "session_policy":"\(policy)","session_id":null,"quiet_period_minutes":60,"model":null,
             "supervision_enabled":false,"supervision_model":null,"stopped":false,"stopped_reason":null,
             "last_fire_at_ms":null,"last_success_at_ms":null,"next_fire_at_ms":1793606400000,
             "created_at_ms":1,"updated_at_ms":2,"last_run":null,"gate_source":null}
            """
        return Data(json.utf8)
    }

    private func detail(runAt: String?, cadence: String? = nil, policy: String = "fresh") throws
        -> ScheduledTaskDetail
    {
        try JSONDecoder().decode(
            ScheduledTaskDetail.self, from: taskJSON(runAt: runAt, cadence: cadence, policy: policy))
    }

    // MARK: - the wire

    func testTheListShowsWhenAOneTimeTaskFiresInBerlinTime() async throws {
        let task = try JSONDecoder().decode(
            ScheduledTask.self, from: taskJSON(runAt: "2026-11-02T08:00:00.250000+00:00"))

        XCTAssertEqual(SchedulerTaskDisplay.whenLabel(task), "once · 2026-11-02 09:00")
    }

    func testATaskFromABackendWithoutTheFieldStillReadsAsItsCadence() async throws {
        let task = try JSONDecoder().decode(
            ScheduledTask.self, from: taskJSON(runAt: nil, cadence: "0 9 * * 1"))

        XCTAssertNil(task.runAt)
        XCTAssertEqual(SchedulerTaskDisplay.whenLabel(task), "0 9 * * 1")
    }

    /// The server's PATCH leaves an omitted key alone, so a task moved from "once" to a cadence
    /// keeps its old instant — and is refused for carrying both — unless `null` is written.
    func testTheWriteBodyAlwaysCarriesRunAtEvenWhenCleared() async throws {
        var fields = TaskWriteFields.fresh(timezone: "Europe/Berlin")
        fields.cadence = "0 9 * * 1"
        fields.runAt = nil

        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fields)) as? [String: Any]

        XCTAssertNotNil(body?.index(forKey: "run_at"))
        XCTAssertTrue(body?["run_at"] is NSNull)
    }

    // MARK: - the editor

    func testSavingOnceSendsTheInstantInWholeMinutesAndNoCadence() async throws {
        let api = FakeTaskEditorApi()
        await api.setCreateResult(.success(try detail(runAt: "2026-11-02T08:00:00+00:00")))
        let store = TaskEditorStore(taskId: nil, api: api, timezone: "Europe/Berlin")
        store.fields.name = "s-recheck"
        store.fields.cadence = "0 9 * * *"
        store.setScheduleMode(.once)
        store.runAtDate = Date(timeIntervalSince1970: 1_793_606_437)  // 2026-11-02T08:00:37Z

        _ = await store.save()

        let sent = await api.createCalls.first
        XCTAssertNil(sent?.cadence)
        XCTAssertEqual(sent?.runAt, "2026-11-02T08:00:00Z")
    }

    func testALoadedOneTimeTaskOpensOnItsInstantAndDropsItWhenMovedToACadence() async throws {
        let api = FakeTaskEditorApi()
        await api.setGetResult(.success(try detail(runAt: "2026-11-02T08:00:00+00:00")))
        await api.setUpdateResult(.success(try detail(runAt: nil, cadence: "0 9 * * 1")))
        let store = TaskEditorStore(taskId: "t1", api: api, timezone: "UTC")
        await store.load()
        XCTAssertEqual(store.scheduleMode, .once)
        XCTAssertEqual(store.runAtDate.timeIntervalSince1970, 1_793_606_400)

        store.setScheduleMode(.cadence)
        store.fields.cadence = "0 9 * * 1"
        _ = await store.save()

        let sent = await api.updateCalls.first?.fields
        XCTAssertEqual(sent?.cadence, "0 9 * * 1")
        XCTAssertNil(sent?.runAt)
    }

    func testOnlyByHandSendsNeitherCadenceNorInstant() async throws {
        let api = FakeTaskEditorApi()
        await api.setGetResult(.success(try detail(runAt: "2026-11-02T08:00:00+00:00")))
        await api.setUpdateResult(.success(try detail(runAt: nil)))
        let store = TaskEditorStore(taskId: "t1", api: api, timezone: "UTC")
        await store.load()
        store.fields.cadence = "0 9 * * 1"

        store.setScheduleMode(.manual)
        _ = await store.save()

        let sent = await api.updateCalls.first?.fields
        XCTAssertNil(sent?.cadence)
        XCTAssertNil(sent?.runAt)
    }

    /// The server refuses a run time on the one-shot policy, which would delete the conversation
    /// the run leaves behind.
    func testChoosingOnceMovesOffTheOneShotPolicy() async {
        let store = TaskEditorStore(taskId: nil, api: FakeTaskEditorApi(), timezone: "UTC")
        store.fields.sessionPolicy = .oneShot

        store.setScheduleMode(.once)

        XCTAssertEqual(store.fields.sessionPolicy, .fresh)
    }
}
