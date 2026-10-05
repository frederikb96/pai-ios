import XCTest

@testable import PAIKit

private let catalogResponse: SessionModelsResponse = {
    let json = """
        {"models":[{"id":"haiku","effort_levels":[]},
                   {"id":"sonnet","effort_levels":["low","medium","high"]},
                   {"id":"opus","effort_levels":["low","medium","high","xhigh","max"]}],
         "fast_default_model":"sonnet","fast_default_thinking":"low"}
        """
    return try! JSONDecoder().decode(SessionModelsResponse.self, from: Data(json.utf8))
}()

private func taskDetail(extra: String = "") -> ScheduledTaskDetail {
    let json = """
        {"id":"t1","name":"Task","enabled":true,"environment":"home","working_dir":null,"prompt":"p",
         "append_system_prompt":"stand","cadence":null,"timezone":"UTC","has_gate":false,
         "gate_runtime":null,"gate_timeout_seconds":30,"session_policy":"fresh","session_id":null,
         "quiet_period_minutes":60,"model":"opus","supervision_enabled":true,"supervision_model":null,
         "stopped":false,"stopped_reason":null,"last_fire_at_ms":null,"last_success_at_ms":null,
         "next_fire_at_ms":null,"created_at_ms":1,"updated_at_ms":2,"gate_source":null\(extra)}
        """
    return try! JSONDecoder().decode(ScheduledTaskDetail.self, from: Data(json.utf8))
}

private func encoded(_ fields: TaskWriteFields) throws -> [String: Any] {
    let data = try JSONEncoder().encode(fields)
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

final class SchedulerThinkingWireTests: XCTestCase {

    /// A supervisor has no default model of its own: its model is an alias or nil, the plan's own.
    func testSessionModelsCarriesNoSupervisorDefault() throws {
        XCTAssertEqual(catalogResponse.models.map(\.id), ["haiku", "sonnet", "opus"])
        let mirror = Mirror(reflecting: catalogResponse).children.compactMap(\.label)
        XCTAssertFalse(mirror.contains("supervisorDefaultModel"))
    }

    func testTaskDecodesBothThinkingFieldsAndReadsAnOlderBackendAsNil() {
        let task = taskDetail(extra: #","thinking":"high","supervision_thinking":"low""#)
        XCTAssertEqual(task.thinking, "high")
        XCTAssertEqual(task.supervisionThinking, "low")
        XCTAssertNil(taskDetail().thinking)
        XCTAssertNil(taskDetail().supervisionThinking)
    }

    func testSupervisionAndItsAttachFormCarryThinking() throws {
        let json = """
            {"id":"sup1","worker_session_id":"s1","task_id":null,"state":"active","memo":null,
             "cursor_message_id":null,"model":"default","thinking":"high","created_at_ms":0,"updated_at_ms":0}
            """
        let supervision = try JSONDecoder().decode(Supervision.self, from: Data(json.utf8))
        XCTAssertEqual(supervision.thinking, "high")
        let config = SupervisionConfigFields.from(supervision)
        XCTAssertEqual(config.thinking, "high")
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any]
        XCTAssertEqual(body?["thinking"] as? String, "high")
    }

    /// An explicit `null` clears the level on the server; an omitted key would leave it set.
    func testTheWriteBodyAlwaysCarriesBothKeysAndPassesLevelsThrough() throws {
        let cleared = try encoded(.from(taskDetail()))
        XCTAssertTrue(cleared["thinking"] is NSNull)
        XCTAssertTrue(cleared["supervision_thinking"] is NSNull)
        let set = try encoded(.from(taskDetail(extra: #","thinking":"high","supervision_thinking":"low""#)))
        XCTAssertEqual(set["thinking"] as? String, "high")
        XCTAssertEqual(set["supervision_thinking"] as? String, "low")
    }

    /// The editor writes every key, so a field `from` forgets to copy is cleared on the server by
    /// the next save from the phone.
    func testEditingATaskKeepsItsOtherSupervisionSettings() throws {
        let task = taskDetail(
            extra:
                #","supervision_append_prompt":"watch closely","supervision_compaction_threshold_tokens":5000,"supervision_chunk_interval_seconds":30,"supervision_chunk_token_threshold":900"#
        )
        let body = try encoded(.from(task))
        XCTAssertEqual(body["supervision_append_prompt"] as? String, "watch closely")
        XCTAssertEqual(body["supervision_compaction_threshold_tokens"] as? Int, 5000)
        XCTAssertEqual(body["supervision_chunk_interval_seconds"] as? Int, 30)
        XCTAssertEqual(body["supervision_chunk_token_threshold"] as? Int, 900)
    }
}

final class SessionModelCatalogTests: XCTestCase {

    private let catalog = SessionModelCatalog(catalogResponse)

    func testLevelsComeFromTheCatalogAndAreEmptyWithoutANamedModel() {
        XCTAssertEqual(catalog.levels(for: "sonnet"), ["low", "medium", "high"])
        XCTAssertEqual(catalog.levels(for: "haiku"), [])
        XCTAssertEqual(catalog.levels(for: nil), [])
        XCTAssertEqual(catalog.levels(for: "unknown"), [])
    }

    func testARetainedLevelMustBeOneTheModelAccepts() {
        XCTAssertEqual(catalog.retainedThinking("high", model: "opus"), "high")
        XCTAssertNil(catalog.retainedThinking("xhigh", model: "sonnet"))
        XCTAssertNil(catalog.retainedThinking("high", model: nil))
        XCTAssertNil(catalog.retainedThinking(nil, model: "opus"))
    }
}

@MainActor
final class SchedulerThinkingStoreTests: XCTestCase {

    private func makeStore() async -> TaskEditorStore {
        let api = FakeTaskEditorApi()
        await api.setSessionModelsResult(.success(catalogResponse))
        let store = TaskEditorStore(taskId: nil, api: api, timezone: "UTC")
        await store.loadCatalog()
        return store
    }

    func testTheWorkerRowAppearsOnlyOnceAModelWithLevelsIsNamed() async {
        let store = await makeStore()
        XCTAssertEqual(store.workerThinkingLevels, [], "Default model: no levels on offer")
        store.setModel("sonnet")
        XCTAssertEqual(store.workerThinkingLevels, ["low", "medium", "high"])
        store.fields.environment = "fast"
        XCTAssertEqual(store.workerThinkingLevels, [], "a fast session always runs Sonnet")
    }

    func testChoosingDefaultOrAModelThatLacksTheLevelDropsIt() async {
        let store = await makeStore()
        store.setModel("opus")
        store.fields.thinking = "xhigh"
        store.setModel("sonnet")
        XCTAssertNil(store.fields.thinking, "sonnet has no xhigh")
        store.fields.thinking = "high"
        store.setModel("opus")
        XCTAssertEqual(store.fields.thinking, "high", "a level the new model accepts survives")
        store.setModel(nil)
        XCTAssertNil(store.fields.thinking)
    }

    /// A supervisor is configured like the worker: nil is the plan's own model, which takes no level.
    func testTheSupervisorOffersLevelsOnlyOnceAModelIsNamed() async {
        let store = await makeStore()
        XCTAssertNil(store.fields.supervisionModel)
        XCTAssertEqual(store.supervisorThinkingLevels, [], "Default: no levels, the server refuses one")
        store.setSupervisionModel("opus")
        XCTAssertEqual(store.supervisorThinkingLevels, ["low", "medium", "high", "xhigh", "max"])
        store.fields.supervisionThinking = "max"
        store.setSupervisionModel(nil)
        XCTAssertNil(store.fields.supervisionThinking, "choosing Default drops the level")
    }

    func testChoosingAnotherSupervisorModelKeepsOnlyALevelItAccepts() async {
        let store = await makeStore()
        store.setSupervisionModel("opus")
        store.fields.supervisionThinking = "high"
        store.setSupervisionModel("sonnet")
        XCTAssertEqual(store.fields.supervisionThinking, "high")
        store.fields.supervisionThinking = "high"
        store.setSupervisionModel("haiku")
        XCTAssertNil(store.fields.supervisionThinking)
    }

    func testTheAttachFormStoreAppliesTheSameRules() async {
        let api = FakeSupervisionApi()
        await api.setSessionModelsResult(.success(catalogResponse))
        let store = SupervisionStore(sessionId: "s1", api: api)
        await store.loadCatalog()
        XCTAssertEqual(store.thinkingLevels, [])
        store.setModel("opus")
        store.config.thinking = "max"
        XCTAssertEqual(store.thinkingLevels.last, "max")
        store.setModel(nil)
        XCTAssertNil(store.config.thinking)
    }
}

final class SchedulerRerunQueuedTests: XCTestCase {

    func testTheQueuedDispositionDecodesAndRoundTripsInsteadOfFallingIntoUnrecognized() throws {
        let decoded = try JSONDecoder().decode(TaskRunDisposition.self, from: Data(#""queued""#.utf8))
        XCTAssertEqual(decoded, .queued)
        XCTAssertEqual(try JSONEncoder().encode(TaskRunDisposition.queued), Data(#""queued""#.utf8))
    }

    func testThePendingReRunDecodesAndIsNilWhenAbsentOrNull() {
        XCTAssertEqual(taskDetail(extra: #","rerun_pending_at_ms":1700000000000"#).rerunPendingAtMs, 1_700_000_000_000)
        XCTAssertNil(taskDetail(extra: #","rerun_pending_at_ms":null"#).rerunPendingAtMs)
        XCTAssertNil(taskDetail().rerunPendingAtMs)
    }

    /// Read-only: the editor writes every key it knows, and the server refuses one it does not.
    func testTheWriteBodyNeverCarriesIt() throws {
        let body = try encoded(.from(taskDetail(extra: #","rerun_pending_at_ms":5"#)))
        XCTAssertNil(body["rerun_pending_at_ms"])
    }
}
