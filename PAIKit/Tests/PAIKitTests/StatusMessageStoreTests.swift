import XCTest

@testable import PAIKit

private actor FakeStatusMessageApi: StatusMessageApiClient {
    var current = StatusMessage(text: nil, expiresAt: nil, active: false, updatedAt: nil)
    private(set) var updates: [StatusMessageUpdate] = []
    private(set) var clears = 0

    func getStatusMessage() async throws -> StatusMessage { current }

    func setStatusMessage(_ update: StatusMessageUpdate) async throws -> StatusMessage {
        updates.append(update)
        current = StatusMessage(
            text: update.text, expiresAt: update.expiresAt, active: true, updatedAt: "2026-10-14T10:00:00+00:00")
        return current
    }

    func clearStatusMessage() async throws -> StatusMessage {
        clears += 1
        current = StatusMessage(text: nil, expiresAt: nil, active: false, updatedAt: "2026-10-14T10:00:00+00:00")
        return current
    }
}

@MainActor
final class StatusMessageStoreTests: XCTestCase {

    func testTheWireShapeUsesTheContractsFieldNames() async throws {
        let json = """
            {"text":"away","expires_at":"2026-10-21T00:00:00+02:00","active":true,\
            "updated_at":"2026-10-14T10:00:00.123456+00:00"}
            """
        let decoded = try JSONDecoder().decode(StatusMessage.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.text, "away")
        XCTAssertEqual(decoded.expiresAt, "2026-10-21T00:00:00+02:00")
        XCTAssertTrue(decoded.active)
        XCTAssertEqual(decoded.updatedAt, "2026-10-14T10:00:00.123456+00:00")
    }

    func testAnUpdateWithoutExpiryWritesAnExplicitNull() async throws {
        let body = try JSONEncoder().encode(StatusMessageUpdate(text: "hi", expiresAt: nil))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["text"] as? String, "hi")
        XCTAssertTrue(object["expires_at"] is NSNull)
    }

    func testSaveSendsTheExpiryInTheDevicesOffset() async throws {
        let api = FakeStatusMessageApi()
        let store = StatusMessageStore(api: api, timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 7200)))
        await store.load()

        store.setDraftText("Away until the 21st")
        store.hasExpiry = true
        store.draftExpiry = Date(timeIntervalSince1970: 1_792_533_600)  // 2026-10-20T22:00:00Z
        XCTAssertTrue(store.canSave)
        await store.save()

        let updates = await api.updates
        XCTAssertEqual(
            updates, [StatusMessageUpdate(text: "Away until the 21st", expiresAt: "2026-10-21T00:00:00+02:00")])
        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(store.message?.active, true)
    }

    func testTheFieldStopsAtTheServersLimit() async {
        let store = StatusMessageStore(api: FakeStatusMessageApi())
        store.setDraftText(String(repeating: "a", count: StatusMessage.maxTextLength + 50))
        XCTAssertEqual(store.draftText.count, StatusMessage.maxTextLength)
    }

    func testClearEmptiesTheDraftAndTheExpiry() async {
        let api = FakeStatusMessageApi()
        let store = StatusMessageStore(api: api)
        await store.load()
        store.setDraftText("x")
        store.hasExpiry = true
        await store.save()
        XCTAssertTrue(store.canClear)

        await store.clear()

        let clears = await api.clears
        XCTAssertEqual(clears, 1)
        XCTAssertEqual(store.draftText, "")
        XCTAssertFalse(store.hasExpiry)
        XCTAssertFalse(store.canClear)
    }
}
