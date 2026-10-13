import XCTest

@testable import PAIKit

/// The incremental sync asks "what changed since" with a cursor that must come from the server's
/// clock and must tolerate a row that became visible after the cursor passed its stamp.
@MainActor
final class SessionListSyncCursorTests: XCTestCase {

    private static func session(_ id: String, updatedAt: String) -> Session {
        SessionFixture.make(id: id, updatedAt: updatedAt, lastActivityAt: updatedAt)
    }

    func testTheFirstCursorIsTheServersNewestStampNotTheDeviceClock() async throws {
        let api = FakeSessionListApi()
        let page = [
            Self.session("a", updatedAt: "2020-05-01T10:00:09.500000+00:00"),
            Self.session("b", updatedAt: "2020-05-01T10:00:02.000000+00:00"),
        ]
        await api.setGetSessionsResult { _ in .success(SessionsPage(sessions: page, nextCursor: nil)) }
        let store = SessionListStore(api: api)

        await store.loadInitialSessions()

        XCTAssertEqual(store.lastSessionSync, "2020-05-01T10:00:09.500000+00:00")
    }

    func testAPollStartsABitBeforeTheCursorAndFindsARowThatCommittedLate() async throws {
        let api = FakeSessionListApi()
        let first = [Self.session("a", updatedAt: "2020-05-01T10:00:10+00:00")]
        // Stamped one second before the cursor, visible only now.
        let late = [Self.session("late", updatedAt: "2020-05-01T10:00:09+00:00")]
        await api.setGetSessionsResult { call in
            .success(SessionsPage(sessions: call.since == nil ? first : late, nextCursor: nil))
        }
        let store = SessionListStore(api: api)
        await store.loadInitialSessions()

        await store.pollSyncedSessions()

        let incremental = await api.getSessionsCalls.filter { $0.since != nil }
        XCTAssertEqual(incremental.first?.since, SessionListStore.syncStart("2020-05-01T10:00:10+00:00"))
        XCTAssertEqual(store.syncedSessions.map(\.id).sorted(), ["a", "late"])
    }

    func testTheCursorNeverMovesBackWhenTheOverlapReturnsOnlyOlderRows() async throws {
        let api = FakeSessionListApi()
        let first = [Self.session("a", updatedAt: "2020-05-01T10:00:10+00:00")]
        let older = [Self.session("a", updatedAt: "2020-05-01T10:00:09+00:00")]
        await api.setGetSessionsResult { call in
            .success(SessionsPage(sessions: call.since == nil ? first : older, nextCursor: nil))
        }
        let store = SessionListStore(api: api)
        await store.loadInitialSessions()

        await store.pollSyncedSessions()

        XCTAssertEqual(store.lastSessionSync, "2020-05-01T10:00:10+00:00")
        XCTAssertEqual(store.syncedSessions.first?.updatedAt, "2020-05-01T10:00:10+00:00")
    }

    func testTheStartIsThreeSecondsEarlierInTheServersFormat() {
        XCTAssertEqual(
            SessionListStore.syncStart("2020-05-01T10:00:10.250000+00:00"), "2020-05-01T10:00:07.250Z")
    }
}
