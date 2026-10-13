import XCTest

@testable import PAIKit

/// The session list's rows update live but hold their positions: a change in order is applied in
/// one step after the list has been quiet, never while it is touched, scrolled or scrolled away
/// from its top, and at once for the reader's own actions. The timings here are shrunk so the
/// suite does not idle; every assertion that something has NOT moved is made inside a window
/// shorter than the hold it checks.
@MainActor
final class SessionListOrderSettlingTests: XCTestCase {

    private static let timing = SessionOrderSettler.Timing(
        settle: 80_000_000, settleMax: 600_000_000, interactionIdle: 150_000_000, release: 40_000_000)

    private func makeStore(_ api: FakeSessionListApi) -> SessionListStore {
        SessionListStore(api: api, orderTiming: Self.timing)
    }

    private nonisolated static func session(_ id: String, minute: Int, title: String? = nil, pinnedAt: String? = nil)
        -> Session
    {
        let at = "2026-01-01T10:0\(minute):00Z"
        return SessionFixture.make(
            id: id, title: title, pinnedAt: pinnedAt, updatedAt: at, lastActivityAt: at)
    }

    /// A store holding `a` (newest) and `b`, whose next incremental poll answers with `changed`.
    private func loaded(changed: [Session]) async -> (SessionListStore, FakeSessionListApi) {
        let api = FakeSessionListApi()
        let initial = [Self.session("a", minute: 5), Self.session("b", minute: 4)]
        await api.setGetSessionsResult { call in
            .success(SessionsPage(sessions: call.since == nil ? initial : changed, nextCursor: nil))
        }
        let store = makeStore(api)
        await store.loadInitialSessions()
        return (store, api)
    }

    private func ids(_ store: SessionListStore) -> [String] { store.rows.map(\.id) }

    private func awaitIds(
        _ store: SessionListStore, _ expected: [String], file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = ContinuousClock().now + .seconds(5)
        while ContinuousClock().now < deadline {
            if ids(store) == expected { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(ids(store), expected, file: file, line: line)
    }

    /// The order stays put for a window.
    private func assertIdsStay(
        _ store: SessionListStore, _ expected: [String], milliseconds: Int, file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock().now + .milliseconds(milliseconds)
        while ContinuousClock().now < deadline {
            guard ids(store) == expected else {
                XCTFail("order became \(ids(store)) instead of staying \(expected)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testARowUpdatesAtOnceButMovesOnlyAfterTheListHasSettled() async {
        let (store, _) = await loaded(changed: [Self.session("b", minute: 9, title: "renamed")])
        XCTAssertEqual(ids(store), ["a", "b"])

        await store.pollSyncedSessions()

        XCTAssertEqual(store.rows.first { $0.id == "b" }?.displayTitle, "renamed")
        XCTAssertEqual(ids(store), ["a", "b"])
        await awaitIds(store, ["b", "a"])
    }

    func testASettleBumpsTheRevisionTheViewAnimatesAgainst() async {
        let (store, _) = await loaded(changed: [Self.session("b", minute: 9)])
        let before = store.orderRevision

        await store.pollSyncedSessions()
        await awaitIds(store, ["b", "a"])

        XCTAssertEqual(store.orderRevision, before + 1)
    }

    func testARowNewToTheListWaitsAtTheBottomInsteadOfPushingTheRestDown() async {
        let (store, _) = await loaded(changed: [Self.session("n", minute: 8)])

        await store.pollSyncedSessions()

        XCTAssertEqual(ids(store), ["a", "b", "n"])
        await awaitIds(store, ["n", "a", "b"])
    }

    func testTheOrderIsHeldWhileTheListIsInUseThenAppliedOnce() async {
        let (store, _) = await loaded(changed: [Self.session("b", minute: 9)])
        await store.pollSyncedSessions()

        // Scrolling for much longer than a settle takes.
        for _ in 0..<12 {
            store.noteListInteraction()
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(ids(store), ["a", "b"])

        await awaitIds(store, ["b", "a"])
    }

    func testAFingerOnTheListHoldsTheOrderForAsLongAsItStaysThere() async {
        let (store, _) = await loaded(changed: [Self.session("b", minute: 9)])
        store.setListTouching(true)
        await store.pollSyncedSessions()

        await assertIdsStay(store, ["a", "b"], milliseconds: 400)

        store.setListTouching(false)
        await awaitIds(store, ["b", "a"])
    }

    func testAListScrolledAwayFromTheTopKeepsItsRowsWhereTheyAreUntilItReturns() async {
        let (store, _) = await loaded(changed: [Self.session("b", minute: 9)])
        store.setListAwayFromTop(true)
        await store.pollSyncedSessions()

        await assertIdsStay(store, ["a", "b"], milliseconds: 800)

        store.setListAwayFromTop(false)
        await awaitIds(store, ["b", "a"])
    }

    func testALeavingTheScreenLetsTheOrderCatchUp() async {
        let (store, _) = await loaded(changed: [Self.session("b", minute: 9)])
        store.setListAwayFromTop(true)
        await store.pollSyncedSessions()

        store.releaseListHold()

        await awaitIds(store, ["b", "a"])
    }

    func testPinningMovesTheRowAtOnce() async {
        let (store, _) = await loaded(changed: [])

        store.togglePinned(id: "b")

        XCTAssertEqual(ids(store), ["b", "a"])
    }

    func testAMessageTheReaderSentMovesItsSessionToTheTopAtOnce() async {
        let (store, _) = await loaded(changed: [])

        store.noteOwnSend(sessionId: "b")

        XCTAssertEqual(ids(store), ["b", "a"])
    }
}
