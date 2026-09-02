import XCTest

@testable import PAIKit

private actor FakeNotificationCenterApi: NotificationCenterApiClient {
    var listResult: Result<NotificationsResponse, PaiError> = .success(
        NotificationsResponse(unread: 0, hasMore: false, notifications: []))
    var summaryResult: Result<NotificationSummary, PaiError> = .success(NotificationSummary(unread: 0, latestId: nil))
    var markReadResult: Result<Int, PaiError> = .success(1)
    var markAllReadResult: Result<Int, PaiError> = .success(0)

    private(set) var listCalls: [(limit: Int?, beforeId: String?, kind: PaiNotificationKind?)] = []
    private(set) var markReadCalls: [[String]] = []
    private(set) var markAllReadCallCount = 0

    func setListResult(_ result: Result<NotificationsResponse, PaiError>) { listResult = result }
    func setMarkReadResult(_ result: Result<Int, PaiError>) { markReadResult = result }

    func getNotifications(
        limit: Int?, beforeId: String?, kind: PaiNotificationKind?
    ) async throws -> NotificationsResponse {
        listCalls.append((limit, beforeId, kind))
        switch listResult {
        case let .success(response): return response
        case let .failure(error): throw error
        }
    }

    func getNotificationsSummary() async throws -> NotificationSummary {
        switch summaryResult {
        case let .success(summary): return summary
        case let .failure(error): throw error
        }
    }

    @discardableResult
    func markNotificationsRead(ids: [String]) async throws -> Int {
        markReadCalls.append(ids)
        switch markReadResult {
        case let .success(count): return count
        case let .failure(error): throw error
        }
    }

    @discardableResult
    func markAllNotificationsRead() async throws -> Int {
        markAllReadCallCount += 1
        switch markAllReadResult {
        case let .success(count): return count
        case let .failure(error): throw error
        }
    }
}

@MainActor
final class NotificationCenterStoreTests: XCTestCase {

    private func makeNotification(
        id: String, kind: PaiNotificationKind = .agent, readAt: String? = nil, sessionId: String? = "s1",
        anchor: PaiNotificationAnchor? = nil, alert: PaiNotificationAlert? = nil
    ) -> PaiNotification {
        PaiNotification(
            id: id, kind: kind, title: "Title \(id)", body: "Body \(id)", createdAt: "2026-01-01T00:00:00Z",
            readAt: readAt, sessionId: sessionId, sessionTitle: "Session", anchor: anchor, alert: alert
        )
    }

    func testLoadInitialReplacesRowsAndTracksUnread() async {
        let api = FakeNotificationCenterApi()
        await api.setListResult(
            .success(
                NotificationsResponse(unread: 2, hasMore: true, notifications: [makeNotification(id: "1")])))
        let store = NotificationCenterStore(api: api)

        await store.loadInitialNotifications()

        XCTAssertEqual(store.rows.map(\.id), ["1"])
        XCTAssertEqual(store.unread, 2)
        XCTAssertTrue(store.hasMoreRows)
    }

    /// The filter change requeries with the new kind and replaces the page — never appends, since
    /// switching segments is a fresh view of the feed, not a continuation of it.
    func testChangingFilterReloadsWithTheNewKind() async {
        let api = FakeNotificationCenterApi()
        let store = NotificationCenterStore(api: api)
        await store.loadInitialNotifications()

        await store.setFilter(.alert)

        let calls = await api.listCalls
        XCTAssertEqual(calls.count, 2)
        XCTAssertNil(calls[0].kind)
        XCTAssertEqual(calls[1].kind, .alert)
        XCTAssertEqual(store.filter, .alert)
    }

    /// Setting the same filter again must not requery — the whole point of the guard is to leave
    /// the loaded page and its scroll position untouched.
    func testSettingTheSameFilterIsANoOp() async {
        let api = FakeNotificationCenterApi()
        let store = NotificationCenterStore(api: api)
        await store.loadInitialNotifications()

        await store.setFilter(.all)

        let calls = await api.listCalls
        XCTAssertEqual(calls.count, 1)
    }

    func testLoadMoreAppendsRatherThanReplacing() async {
        let api = FakeNotificationCenterApi()
        await api.setListResult(
            .success(NotificationsResponse(unread: 0, hasMore: true, notifications: [makeNotification(id: "1")])))
        let store = NotificationCenterStore(api: api)
        await store.loadInitialNotifications()

        await api.setListResult(
            .success(NotificationsResponse(unread: 0, hasMore: false, notifications: [makeNotification(id: "2")])))
        await store.loadMoreRows()

        XCTAssertEqual(store.rows.map(\.id), ["1", "2"])
        XCTAssertFalse(store.hasMoreRows)
        let calls = await api.listCalls
        XCTAssertEqual(calls[1].beforeId, "1")
    }

    /// `loadMoreRows` with nothing more to load, or already loading, must not double-fetch.
    func testLoadMoreDoesNothingWithoutMoreRows() async {
        let api = FakeNotificationCenterApi()
        await api.setListResult(
            .success(NotificationsResponse(unread: 0, hasMore: false, notifications: [makeNotification(id: "1")])))
        let store = NotificationCenterStore(api: api)
        await store.loadInitialNotifications()

        await store.loadMoreRows()

        let calls = await api.listCalls
        XCTAssertEqual(calls.count, 1)
    }

    func testMarkReadIsOptimisticAndDecrementsUnread() async {
        let api = FakeNotificationCenterApi()
        await api.setListResult(
            .success(NotificationsResponse(unread: 1, hasMore: false, notifications: [makeNotification(id: "1")])))
        let store = NotificationCenterStore(api: api)
        await store.loadInitialNotifications()

        await store.markRead("1")

        XCTAssertFalse(store.rows[0].isUnread)
        XCTAssertEqual(store.unread, 0)
        let calls = await api.markReadCalls
        XCTAssertEqual(calls, [["1"]])
    }

    /// A read state the server never recorded must not stick locally — the next launch's
    /// `refreshSummary()` would disagree with it forever otherwise.
    func testMarkReadRevertsOnFailure() async {
        let api = FakeNotificationCenterApi()
        await api.setListResult(
            .success(NotificationsResponse(unread: 1, hasMore: false, notifications: [makeNotification(id: "1")])))
        await api.setMarkReadResult(.failure(.transport("offline")))
        let store = NotificationCenterStore(api: api)
        await store.loadInitialNotifications()

        await store.markRead("1")

        XCTAssertTrue(store.rows[0].isUnread)
        XCTAssertEqual(store.unread, 1)
    }

    /// Marking an already-read row read again is a no-op — no call, no unread underflow.
    func testMarkReadOnAnAlreadyReadRowDoesNothing() async {
        let api = FakeNotificationCenterApi()
        await api.setListResult(
            .success(
                NotificationsResponse(
                    unread: 0, hasMore: false,
                    notifications: [makeNotification(id: "1", readAt: "2026-01-01T00:00:00Z")])))
        let store = NotificationCenterStore(api: api)
        await store.loadInitialNotifications()

        await store.markRead("1")

        let calls = await api.markReadCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testMarkAllReadClearsEveryRowAndTheCount() async {
        let api = FakeNotificationCenterApi()
        await api.setListResult(
            .success(
                NotificationsResponse(
                    unread: 2, hasMore: false,
                    notifications: [makeNotification(id: "1"), makeNotification(id: "2")])))
        let store = NotificationCenterStore(api: api)
        await store.loadInitialNotifications()

        await store.markAllRead()

        XCTAssertTrue(store.rows.allSatisfy { !$0.isUnread })
        XCTAssertEqual(store.unread, 0)
        let count = await api.markAllReadCallCount
        XCTAssertEqual(count, 1)
    }

    /// A cold push tap resolves and opens a session directly, without the centre ever having
    /// loaded a page — `markRead` still has to tell the backend in that case.
    func testMarkReadOnARowNotLocallyLoadedStillCallsTheBackend() async {
        let api = FakeNotificationCenterApi()
        let store = NotificationCenterStore(api: api)

        await store.markRead("not-loaded")

        let calls = await api.markReadCalls
        XCTAssertEqual(calls, [["not-loaded"]])
        XCTAssertTrue(store.rows.isEmpty)
    }

    func testFocusIsConsumedOnce() {
        let api = FakeNotificationCenterApi()
        let store = NotificationCenterStore(api: api)
        store.focus(id: "n1")

        XCTAssertEqual(store.consumePendingFocus(), "n1")
        XCTAssertNil(store.consumePendingFocus())
    }
}
