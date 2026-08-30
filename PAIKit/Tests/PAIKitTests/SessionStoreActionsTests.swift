import XCTest
@testable import PAIKit

/// `SessionActionsStore` is mostly one mutation shape repeated (call the endpoint, write the
/// result back into `SessionListStore`) — these tests target the two places that shape can
/// silently break: a successful mutation must reach the list, and a failed one must never
/// silently swallow its error or write a stale row over a real one. `close()` gets its own tests
/// because it is the one mutation whose "did this actually work" reads a status field rather than
/// throwing.
@MainActor
final class SessionStoreActionsTests: XCTestCase {

    private func makeListStore(session: Session) async -> (SessionListStore, FakeSessionListApi) {
        let listApi = FakeSessionListApi()
        await listApi.setGetSessionsResult { _ in .success(SessionsPage(sessions: [session], nextCursor: nil)) }
        let store = SessionListStore(api: listApi)
        return (store, listApi)
    }

    func testRenameWritesTheServersSessionBackIntoTheList() async {
        let (listStore, _) = await makeListStore(session: SessionFixture.make(id: "s1", title: nil))
        await listStore.loadInitialSessions()
        let actionsApi = FakeSessionActionsApi()
        await actionsApi.setSessionResult(.success(SessionFixture.make(id: "s1", title: "Renamed")))
        let store = SessionActionsStore(sessionId: "s1", sessionList: listStore, api: actionsApi)

        let ok = await store.rename(title: "Renamed")

        XCTAssertTrue(ok)
        XCTAssertEqual(listStore.session(withId: "s1")?.title, "Renamed")
        XCTAssertNil(store.errorMessage)
    }

    func testRenameIsANoOpForBlankText() async {
        let (listStore, _) = await makeListStore(session: SessionFixture.make(id: "s1"))
        let actionsApi = FakeSessionActionsApi()
        let store = SessionActionsStore(sessionId: "s1", sessionList: listStore, api: actionsApi)

        let ok = await store.rename(title: "   ")

        XCTAssertFalse(ok)
        let calls = await actionsApi.renameCalls
        XCTAssertTrue(calls.isEmpty, "a blank rename must never reach the server")
    }

    func testAFailedMutationSetsAnErrorAndLeavesTheListRowUntouched() async {
        let (listStore, _) = await makeListStore(session: SessionFixture.make(id: "s1", title: "original"))
        await listStore.loadInitialSessions()
        let actionsApi = FakeSessionActionsApi()
        await actionsApi.setSessionResult(.failure(.transport("offline")))
        let store = SessionActionsStore(sessionId: "s1", sessionList: listStore, api: actionsApi)

        let ok = await store.rename(title: "New name")

        XCTAssertFalse(ok)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(listStore.session(withId: "s1")?.title, "original")
    }

    func testCloseReportedAsCloseErrorSurfacesTheDetailRatherThanReadingAsSuccess() async {
        let (listStore, _) = await makeListStore(session: SessionFixture.make(id: "s1"))
        let actionsApi = FakeSessionActionsApi()
        await actionsApi.setCloseResult(.success(CloseResponse(status: .closeError, detail: "agent unreachable")))
        let store = SessionActionsStore(sessionId: "s1", sessionList: listStore, api: actionsApi)

        let ok = await store.close()

        XCTAssertFalse(ok, "close_error is not a thrown error, so a caller reading only 'did it throw' would miss it")
        XCTAssertEqual(store.errorMessage, "agent unreachable")
    }

    func testCloseAlreadyClosedReadsAsSuccess() async {
        let (listStore, _) = await makeListStore(session: SessionFixture.make(id: "s1"))
        let actionsApi = FakeSessionActionsApi()
        await actionsApi.setCloseResult(.success(CloseResponse(status: .alreadyClosed, detail: nil)))
        let store = SessionActionsStore(sessionId: "s1", sessionList: listStore, api: actionsApi)

        let ok = await store.close()

        XCTAssertTrue(ok)
    }

    // MARK: - ExportPreset

    func testExportPresetAllOmitsSinceEntirely() {
        XCTAssertNil(ExportPreset.all.sinceIso())
    }

    func testExportPresetLastHourIsExactlyOneHourBeforeNow() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let since = ExportPreset.lastHour.sinceIso(now: now)
        XCTAssertEqual(since, ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_750_000_000 - 3600)))
    }

    func testDeleteWithHoldDelegatesToTheListStoreRatherThanCallingTheApiDirectly() async {
        let (listStore, _) = await makeListStore(session: SessionFixture.make(id: "s1"))
        await listStore.loadInitialSessions()
        let actionsApi = FakeSessionActionsApi()
        let store = SessionActionsStore(sessionId: "s1", sessionList: listStore, api: actionsApi)

        store.deleteWithHold()

        XCTAssertTrue(listStore.syncedSessions.isEmpty)
        XCTAssertEqual(listStore.pendingDelete?.session.id, "s1")
    }
}

/// `OffsetPagedListStore` is the move-to-project/move-to-phase pickers' shared paging engine —
/// these tests target its two real hazards: a query change must reload from the top rather than
/// appending, and a slower, superseded page must never land after a faster, more recent one
/// (the same race class `SessionStoreListStoreTests` covers for the main list, minus the debounce
/// this type deliberately has none of — see its doc comment).
@MainActor
final class OffsetPagedListStoreTests: XCTestCase {

    private struct Row: Sendable, Identifiable, Equatable {
        let id: String
    }

    func testLoadMoreAppendsAtTheCurrentItemCountAsTheOffset() async {
        let seenOffsets = OffsetLog()
        let store = OffsetPagedListStore<Row> { _, limit, offset in
            await seenOffsets.record(offset)
            if offset == 0 {
                return (items: (0..<limit).map { Row(id: "\($0)") }, hasMore: true)
            }
            return (items: [Row(id: "extra")], hasMore: false)
        }

        await store.reload()
        await store.loadMore()

        let recorded = await seenOffsets.values
        XCTAssertEqual(recorded, [0, OffsetPagedListStore<Row>.pageSize])
        XCTAssertEqual(store.items.last?.id, "extra")
        XCTAssertFalse(store.hasMore)
    }

    func testChangingTheQueryReloadsFromTheTopRatherThanAppending() async {
        let store = OffsetPagedListStore<Row> { query, _, offset in
            guard offset == 0 else { return (items: [], hasMore: false) }
            return (items: [Row(id: query)], hasMore: false)
        }
        await store.reload()  // query starts empty

        store.query = "alpha"
        // `query`'s didSet fires a detached Task; wait for it to actually land rather than
        // asserting on a race with it.
        let deadline = ContinuousClock().now + .seconds(5)
        while store.items.map(\.id) != ["alpha"], ContinuousClock().now < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }

        XCTAssertEqual(store.items.map(\.id), ["alpha"], "a query change must replace the list, not append to it")
    }

    func testASlowerStaleReloadNeverOverwritesAFasterNewerOne() async {
        let gate = CallGate()
        await gate.arm("alpha")
        let store = OffsetPagedListStore<Row> { query, _, _ in
            await gate.wait(for: query)
            return (items: [Row(id: query)], hasMore: false)
        }

        let first = Task { await store.reload() }
        // Let the first (gated) reload actually start before firing the second — otherwise both
        // could arrive at the fetch closure before either awaits its gate, and generation
        // ordering, not the gate, would decide which one this test observed.
        try? await Task.sleep(nanoseconds: 5_000_000)
        store.query = "beta"

        let deadline = ContinuousClock().now + .seconds(5)
        while store.items.map(\.id) != ["beta"], ContinuousClock().now < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(store.items.map(\.id), ["beta"])

        await gate.release("alpha")
        _ = await first.value
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(store.items.map(\.id), ["beta"], "the stale alpha reload must lose even though it answers last")
    }
}

private actor OffsetLog {
    private(set) var values: [Int] = []
    func record(_ value: Int) { values.append(value) }
}

extension FakeSessionActionsApi {
    func setSessionResult(_ result: Result<Session, PaiError>) {
        sessionResult = result
    }

    func setCloseResult(_ result: Result<CloseResponse, PaiError>) {
        closeResult = result
    }
}
