import XCTest

@testable import PAIKit

private actor FakeNotificationCenterApi: NotificationCenterApiClient {
    var listResult: Result<NotificationsResponse, PaiError> = .success(
        NotificationsResponse(unread: 0, hasMore: false, notifications: []))
    var summaryResult: Result<NotificationSummary, PaiError> = .success(NotificationSummary(unread: 0, latestId: nil))
    var markReadResult: Result<Int, PaiError> = .success(1)
    var markAllReadResult: Result<Int, PaiError> = .success(0)
    var getNotificationResult: Result<PaiNotification, PaiError> = .failure(.transport("not configured"))
    var clearAlertsResult: Result<Int, PaiError> = .success(1)
    /// Per-id overrides for `getNotification`, checked before the single shared
    /// `getNotificationResult` above — what `readStatus(forIDs:)`'s tests need to prove a
    /// heterogeneous batch (some read, some not, one failed) resolves each id independently.
    var getNotificationResultsById: [String: Result<PaiNotification, PaiError>] = [:]

    private(set) var listCalls: [(limit: Int?, beforeId: String?, kind: PaiNotificationKind?)] = []
    private(set) var markReadCalls: [[String]] = []
    private(set) var markAllReadCallCount = 0
    private(set) var getNotificationCalls: [String] = []
    private(set) var clearAlertsCalls: [[String]] = []

    func setListResult(_ result: Result<NotificationsResponse, PaiError>) { listResult = result }
    func setMarkReadResult(_ result: Result<Int, PaiError>) { markReadResult = result }
    func setGetNotificationResult(_ result: Result<PaiNotification, PaiError>) { getNotificationResult = result }
    func setGetNotificationResult(_ result: Result<PaiNotification, PaiError>, forId id: String) {
        getNotificationResultsById[id] = result
    }
    func setClearAlertsResult(_ result: Result<Int, PaiError>) { clearAlertsResult = result }

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

    func getNotification(id: String) async throws -> PaiNotification {
        getNotificationCalls.append(id)
        switch getNotificationResultsById[id] ?? getNotificationResult {
        case let .success(notification): return notification
        case let .failure(error): throw error
        }
    }

    @discardableResult
    func clearAlerts(ids: [String]) async throws -> Int {
        clearAlertsCalls.append(ids)
        switch clearAlertsResult {
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

    /// A row's anchor is often still null at tap time -- resolution is lazy-on-read on the
    /// server, so the list fetch that populated `rows` frequently ran before the transcript
    /// message was even ingested. A row that already carries one needs no round trip.
    func testResolvedAnchorMessageIDReturnsTheLoadedRowsAnchorWithoutFetching() async {
        let api = FakeNotificationCenterApi()
        await api.setListResult(
            .success(
                NotificationsResponse(
                    unread: 0, hasMore: false,
                    notifications: [makeNotification(id: "1", anchor: PaiNotificationAnchor(messageId: 42))])))
        let store = NotificationCenterStore(api: api)
        await store.loadInitialNotifications()

        let messageId = await store.resolvedAnchorMessageID(for: "1")

        XCTAssertEqual(messageId, 42)
        let calls = await api.getNotificationCalls
        XCTAssertTrue(calls.isEmpty)
    }

    /// The common case: the loaded row's anchor is still null, so this re-fetches the
    /// notification fresh, which is what triggers the server's own lazy resolution.
    func testResolvedAnchorMessageIDRefetchesWhenTheLoadedRowHasNoAnchorYet() async {
        let api = FakeNotificationCenterApi()
        await api.setListResult(
            .success(NotificationsResponse(unread: 0, hasMore: false, notifications: [makeNotification(id: "1")])))
        await api.setGetNotificationResult(
            .success(makeNotification(id: "1", anchor: PaiNotificationAnchor(messageId: 99))))
        let store = NotificationCenterStore(api: api)
        await store.loadInitialNotifications()

        let messageId = await store.resolvedAnchorMessageID(for: "1")

        XCTAssertEqual(messageId, 99)
        let calls = await api.getNotificationCalls
        XCTAssertEqual(calls, ["1"])
    }

    /// Still unresolved after the re-fetch (or the row is gone) -- `nil`, the same "land at the
    /// normal restored position, no jump" degrade the web's own `?n=` fallback settles on.
    func testResolvedAnchorMessageIDIsNilWhenStillUnresolved() async {
        let api = FakeNotificationCenterApi()
        await api.setListResult(
            .success(NotificationsResponse(unread: 0, hasMore: false, notifications: [makeNotification(id: "1")])))
        await api.setGetNotificationResult(.success(makeNotification(id: "1")))
        let store = NotificationCenterStore(api: api)
        await store.loadInitialNotifications()

        let messageId = await store.resolvedAnchorMessageID(for: "1")

        XCTAssertNil(messageId)
    }

    func testFocusIsConsumedOnce() {
        let api = FakeNotificationCenterApi()
        let store = NotificationCenterStore(api: api)
        store.focus(id: "n1")

        XCTAssertEqual(store.consumePendingFocus(), "n1")
        XCTAssertNil(store.consumePendingFocus())
    }

    /// An old alert outside the loaded page has to be fetched on its own and spliced in before
    /// it can ever be expanded — this is what makes that possible.
    func testEnsureLoadedFetchesAndPrependsARowNotAlreadyPresent() async {
        let api = FakeNotificationCenterApi()
        await api.setGetNotificationResult(.success(makeNotification(id: "old", kind: .alert)))
        let store = NotificationCenterStore(api: api)
        await store.loadInitialNotifications()

        await store.ensureLoaded(id: "old")

        XCTAssertEqual(store.rows.map(\.id), ["old"])
        let calls = await api.getNotificationCalls
        XCTAssertEqual(calls, ["old"])
    }

    /// A row already loaded needs no fetch — the whole point of checking first, since fetching
    /// on every focus would be a redundant round trip for the ordinary case.
    func testEnsureLoadedIsANoOpWhenTheRowIsAlreadyPresent() async {
        let api = FakeNotificationCenterApi()
        await api.setListResult(
            .success(NotificationsResponse(unread: 0, hasMore: false, notifications: [makeNotification(id: "1")])))
        let store = NotificationCenterStore(api: api)
        await store.loadInitialNotifications()

        await store.ensureLoaded(id: "1")

        XCTAssertEqual(store.rows.map(\.id), ["1"])
        let calls = await api.getNotificationCalls
        XCTAssertTrue(calls.isEmpty)
    }

    /// The row itself stays — it is a historical record regardless of whether the alert it
    /// describes is still active — only `active` flips, in place.
    func testClearAlertPatchesTheRowInPlaceRatherThanReloading() async {
        let api = FakeNotificationCenterApi()
        let alert = PaiNotificationAlert(
            id: "a1", key: "disk", severity: "warning", source: "vm", transition: "raised", active: true)
        await api.setListResult(
            .success(
                NotificationsResponse(
                    unread: 0, hasMore: false, notifications: [makeNotification(id: "1", kind: .alert, alert: alert)]))
        )
        let store = NotificationCenterStore(api: api)
        await store.loadInitialNotifications()

        let cleared = await store.clearAlert("1")

        XCTAssertTrue(cleared)
        XCTAssertEqual(store.rows.first?.alert?.active, false)
        XCTAssertEqual(store.rows.first?.alert?.id, "a1", "the alert id itself is untouched by the patch")
        let calls = await api.clearAlertsCalls
        XCTAssertEqual(calls, [["a1"]])
        // No second `getNotifications` call beyond the initial load — a reload would have made
        // one, and this is exactly the reload this method exists to avoid.
        let listCalls = await api.listCalls
        XCTAssertEqual(listCalls.count, 1)
    }

    func testClearAlertLeavesTheRowUntouchedOnFailure() async {
        let api = FakeNotificationCenterApi()
        let alert = PaiNotificationAlert(
            id: "a1", key: "disk", severity: "warning", source: "vm", transition: "raised", active: true)
        await api.setListResult(
            .success(
                NotificationsResponse(
                    unread: 0, hasMore: false, notifications: [makeNotification(id: "1", kind: .alert, alert: alert)]))
        )
        await api.setClearAlertsResult(.failure(.transport("offline")))
        let store = NotificationCenterStore(api: api)
        await store.loadInitialNotifications()

        let cleared = await store.clearAlert("1")

        XCTAssertFalse(cleared)
        XCTAssertEqual(store.rows.first?.alert?.active, true)
    }

    /// A row with no `alert.id` (the alert itself has since been purged) has nothing to clear —
    /// the guard rather than a call that would fail anyway.
    func testClearAlertOnARowWithNoAlertIdDoesNothing() async {
        let api = FakeNotificationCenterApi()
        let alert = PaiNotificationAlert(
            id: nil, key: "disk", severity: "warning", source: "vm", transition: "raised", active: false)
        await api.setListResult(
            .success(
                NotificationsResponse(
                    unread: 0, hasMore: false, notifications: [makeNotification(id: "1", kind: .alert, alert: alert)]))
        )
        let store = NotificationCenterStore(api: api)
        await store.loadInitialNotifications()

        let cleared = await store.clearAlert("1")

        XCTAssertFalse(cleared)
        let calls = await api.clearAlertsCalls
        XCTAssertTrue(calls.isEmpty)
    }

    /// What `PaiNotificationStreamClient`'s live events apply — a plain count set, with `rows`
    /// left exactly as loaded.
    func testApplyLiveUnreadSetsTheCountWithoutTouchingRows() async {
        let api = FakeNotificationCenterApi()
        await api.setListResult(
            .success(NotificationsResponse(unread: 1, hasMore: false, notifications: [makeNotification(id: "1")])))
        let store = NotificationCenterStore(api: api)
        await store.loadInitialNotifications()

        store.applyLiveUnread(4)

        XCTAssertEqual(store.unread, 4)
        XCTAssertEqual(store.rows.map(\.id), ["1"])
    }

    /// A heterogeneous batch — one confirmed read, one confirmed still unread, one the fetch
    /// failed for — resolves each id independently, and the failed one is simply absent rather
    /// than defaulted either way.
    func testReadStatusReturnsConfirmedStateAndOmitsFailures() async {
        let api = FakeNotificationCenterApi()
        await api.setGetNotificationResult(
            .success(makeNotification(id: "read1", readAt: "2026-01-01T00:00:00Z")), forId: "read1")
        await api.setGetNotificationResult(.success(makeNotification(id: "unread1")), forId: "unread1")
        await api.setGetNotificationResult(.failure(.transport("offline")), forId: "fail1")
        let store = NotificationCenterStore(api: api)

        let status = await store.readStatus(forIDs: ["read1", "unread1", "fail1"])

        XCTAssertEqual(status, ["read1": true, "unread1": false])
    }

    /// An empty request makes no calls at all — the common case, since most delivered
    /// notifications are already accounted for.
    func testReadStatusWithNoIDsMakesNoCalls() async {
        let api = FakeNotificationCenterApi()
        let store = NotificationCenterStore(api: api)

        let status = await store.readStatus(forIDs: [])

        XCTAssertTrue(status.isEmpty)
        let calls = await api.getNotificationCalls
        XCTAssertTrue(calls.isEmpty)
    }
}
