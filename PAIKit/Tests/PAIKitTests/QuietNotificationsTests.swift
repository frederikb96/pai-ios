import XCTest

@testable import PAIKit

/// The wire half of quiet scheduled notifications: the `scheduled` filter on the feed, the task
/// on every row, the per-task push setting and the mail master switch.
final class QuietNotificationsTests: XCTestCase {

    override func tearDown() {
        PaiStubURLProtocol.reset()
        super.tearDown()
    }

    private func client() throws -> PaiApiClient {
        let factory = try PaiRequestFactory(baseURL: "https://pai.example.com", tokenProvider: { "jwt" })
        return PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
    }

    private func queryItems() -> [String: String] {
        let url = PaiStubURLProtocol.capturedRequest?.url
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private func stubEmptyFeed() {
        PaiStubURLProtocol.stub = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"],
            body: Data(#"{"unread":0,"has_more":false,"notifications":[]}"#.utf8))
    }

    // MARK: the feed filter

    func testTheSourceFilterIsSentAsTheBackendsScheduledParameter() async throws {
        stubEmptyFeed()
        let api = try client()

        _ = try await api.getNotifications(limit: 50, beforeId: "b1", kind: .agent, source: .scheduled)
        XCTAssertEqual(queryItems()["scheduled"], "only")
        XCTAssertEqual(queryItems()["kind"], "agent")
        XCTAssertEqual(queryItems()["before_id"], "b1")

        _ = try await api.getNotifications(source: .notScheduled)
        XCTAssertEqual(queryItems()["scheduled"], "exclude")
    }

    /// The backend answers 400 to any value but `only` and `exclude`, so "any source" must send
    /// no parameter rather than `scheduled=any`.
    func testAnySourceSendsNoScheduledParameter() async throws {
        stubEmptyFeed()
        _ = try await client().getNotifications(limit: 50)
        XCTAssertNil(queryItems()["scheduled"])
    }

    func testRowsDecodeTheirTaskAndOlderRowsDecodeWithout() throws {
        let page = try JSONDecoder().decode(
            NotificationsResponse.self, from: PaiFixtures.notificationsPage(kind: nil, scheduled: nil))
        XCTAssertTrue(page.notifications.contains { $0.taskId != nil && $0.taskName == "Nightly backup" })

        let old = #"""
            {"id":"n","kind":"agent","title":"t","body":"b","created_at":"2026-01-01T00:00:00Z",
             "read_at":null,"session_id":null,"session_title":null,"anchor":null,"alert":null}
            """#
        let row = try JSONDecoder().decode(PaiNotification.self, from: Data(old.utf8))
        XCTAssertNil(row.taskId)
        XCTAssertNil(row.taskName)
    }

    // MARK: the task setting

    private func taskDetail(extra: String) throws -> ScheduledTaskDetail {
        let json = """
            {"id":"t1","name":"Task","enabled":true,"environment":"home","working_dir":null,"prompt":"p",
             "append_system_prompt":null,"cadence":null,"timezone":"UTC","has_gate":false,
             "gate_runtime":null,"gate_timeout_seconds":30,"session_policy":"fresh","session_id":null,
             "quiet_period_minutes":60,"supervision_enabled":false,"supervision_model":null,
             "stopped":false,"stopped_reason":null,"last_fire_at_ms":null,"last_success_at_ms":null,
             "next_fire_at_ms":null,"created_at_ms":1,"updated_at_ms":2,"gate_source":null\(extra)}
            """
        return try JSONDecoder().decode(ScheduledTaskDetail.self, from: Data(json.utf8))
    }

    private func written(_ fields: TaskWriteFields) throws -> [String: Any] {
        let data = try JSONEncoder().encode(fields)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTheEditorReadsTheTasksPushSettingAndWritesItBack() throws {
        let blocking = TaskWriteFields.from(try taskDetail(extra: #","notify_push":"blocking""#))
        XCTAssertEqual(blocking.notifyPush, .blocking)
        XCTAssertEqual(try written(blocking)["notify_push"] as? String, "blocking")

        var all = TaskWriteFields.from(try taskDetail(extra: #","notify_push":"all""#))
        XCTAssertEqual(try written(all)["notify_push"] as? String, "all")
        all.notifyPush = .blocking
        XCTAssertEqual(try written(all)["notify_push"] as? String, "blocking")
    }

    /// A backend without the setting sends no key; the task means `all`, and a brand-new task
    /// starts there too.
    func testAnAbsentPushSettingMeansAll() throws {
        let task = try taskDetail(extra: "")
        XCTAssertNil(task.notifyPush)
        XCTAssertEqual(TaskWriteFields.from(task).notifyPush, .all)
        XCTAssertEqual(try written(TaskWriteFields.fresh(timezone: "UTC"))["notify_push"] as? String, "all")
    }

    func testAnUnknownPushValueSurvivesTheRoundTrip() throws {
        let fields = TaskWriteFields.from(try taskDetail(extra: #","notify_push":"digest""#))
        XCTAssertEqual(fields.notifyPush, .unrecognized("digest"))
        XCTAssertEqual(try written(fields)["notify_push"] as? String, "digest")
    }

    /// The defer cap is cleared by an explicit null (an omitted key would leave the stored cap),
    /// and `deferred_since_ms` is the server's, so it is never written back.
    func testTheDeferCapIsWrittenAsNullWhenCleared() throws {
        var fields = TaskWriteFields.from(try taskDetail(extra: #","max_defer_minutes":90,"deferred_since_ms":5"#))
        XCTAssertEqual(fields.maxDeferMinutes, 90)
        XCTAssertEqual(try written(fields)["max_defer_minutes"] as? Int, 90)
        fields.maxDeferMinutes = nil
        let object = try written(fields)
        XCTAssertTrue(object.keys.contains("max_defer_minutes"))
        XCTAssertTrue(object["max_defer_minutes"] is NSNull)
        XCTAssertFalse(object.keys.contains("deferred_since_ms"))
        XCTAssertEqual(try taskDetail(extra: #","deferred_since_ms":5"#).deferredSinceMs, 5)
    }

    // MARK: mail

    private func smtp(enabled: Bool, alerts: Bool) throws -> SmtpSettings {
        let json = """
            {"host":"h","port":587,"security":"starttls","username":null,"from_address":null,
             "recipient":"a@b.c","enabled":\(enabled),"alerts_enabled":\(alerts),"updated_at":"2026-01-01T00:00:00Z"}
            """
        return try JSONDecoder().decode(SmtpSettings.self, from: Data(json.utf8))
    }

    func testTheDraftCarriesBothSwitchesIntoTheUpdate() throws {
        var draft = SmtpSettingsDraft(loaded: try smtp(enabled: true, alerts: false))
        XCTAssertTrue(draft.enabled)
        XCTAssertFalse(draft.alertsEnabled)
        draft.alertsEnabled = true
        let update = draft.asUpdate()
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as? [String: Any])
        XCTAssertEqual(object["enabled"] as? Bool, true)
        XCTAssertEqual(object["alerts_enabled"] as? Bool, true)
    }

    func testTheRowSummaryNamesWhatIsMailed() async throws {
        let off = try await Self.storeLoaded(with: "\"enabled\":false,\"alerts_enabled\":true")
        let offSummary = await off.summary
        XCTAssertEqual(offSummary, "Off")
        let agentOnly = try await Self.storeLoaded(with: "\"enabled\":true,\"alerts_enabled\":false")
        let agentOnlySummary = await agentOnly.summary
        XCTAssertEqual(agentOnlySummary, "Agent mail only")
        let both = try await Self.storeLoaded(with: "\"enabled\":true,\"alerts_enabled\":true")
        let bothSummary = await both.summary
        XCTAssertEqual(bothSummary, "a@b.c")
    }

    @MainActor
    private static func storeLoaded(with switches: String) async throws -> SmtpSettingsStore {
        PaiStubURLProtocol.stub = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"],
            body: Data(
                """
                {"host":"h","port":587,"security":"starttls","username":null,"from_address":null,
                 "recipient":"a@b.c",\(switches),"updated_at":"2026-01-01T00:00:00Z"}
                """.utf8))
        let factory = try PaiRequestFactory(baseURL: "https://pai.example.com", tokenProvider: { "jwt" })
        let api = PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
        let store = SmtpSettingsStore(apiClient: api)
        await store.load()
        return store
    }
}
