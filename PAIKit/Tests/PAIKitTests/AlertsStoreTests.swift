import XCTest

@testable import PAIKit

private actor FakeAlertsApi: AlertsApiClient {
    var alerts: [PaiAlert]
    var clearFails = false
    private(set) var clearCalls: [[String]] = []

    init(alerts: [PaiAlert]) { self.alerts = alerts }

    func setClearFails(_ value: Bool) { clearFails = value }

    func listAlerts() async throws -> AlertsResponse {
        AlertsResponse(total: alerts.count, alerts: alerts)
    }

    func clearAlerts(ids: [String]) async throws -> Int {
        clearCalls.append(ids)
        if clearFails { throw PaiError.transport("down") }
        return ids.count
    }
}

private func alert(_ id: String) -> PaiAlert {
    PaiAlert(
        id: id, source: "agent", key: "k-\(id)", severity: "critical", message: "m", count: 1,
        createdAt: "2026-10-01T08:22:54.123456+00:00", lastSeenAt: "2026-10-01T08:22:54.123456+00:00")
}

@MainActor
final class AlertsStoreTests: XCTestCase {

    func testAcknowledgeOneSendsOnlyThatIdAndDropsOnlyThatRow() async {
        let api = FakeAlertsApi(alerts: [alert("a"), alert("b")])
        let store = AlertsStore(api: api)
        await store.load()
        await store.acknowledge("a")
        let calls = await api.clearCalls
        XCTAssertEqual(calls, [["a"]])
        XCTAssertEqual(store.alerts?.map(\.id), ["b"])
    }

    /// An empty `ids` would be read by the backend as "clear every alert", so it must never be sent.
    func testAcknowledgeAllNamesEveryListedIdAndNeverSendsAnEmptyList() async {
        let api = FakeAlertsApi(alerts: [alert("a"), alert("b")])
        let store = AlertsStore(api: api)
        await store.load()
        await store.acknowledgeAll()
        await store.acknowledgeAll()
        let calls = await api.clearCalls
        XCTAssertEqual(calls, [["a", "b"]])
        XCTAssertEqual(store.alerts, [])
    }

    func testAFailedClearKeepsTheRowAndReportsTheError() async {
        let api = FakeAlertsApi(alerts: [alert("a")])
        await api.setClearFails(true)
        let store = AlertsStore(api: api)
        await store.load()
        await store.acknowledge("a")
        XCTAssertEqual(store.alerts?.map(\.id), ["a"])
        XCTAssertNotNil(store.errorMessage)
    }
}
