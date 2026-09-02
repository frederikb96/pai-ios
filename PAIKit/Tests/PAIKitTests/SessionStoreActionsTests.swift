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

    func testDeleteNowDelegatesToTheListStoreRatherThanCallingTheApiDirectly() async {
        let (listStore, _) = await makeListStore(session: SessionFixture.make(id: "s1"))
        await listStore.loadInitialSessions()
        let actionsApi = FakeSessionActionsApi()
        let store = SessionActionsStore(sessionId: "s1", sessionList: listStore, api: actionsApi)

        store.deleteNow()

        XCTAssertTrue(listStore.syncedSessions.isEmpty)
    }
}

extension FakeSessionActionsApi {
    func setSessionResult(_ result: Result<Session, PaiError>) {
        sessionResult = result
    }

    func setCloseResult(_ result: Result<CloseResponse, PaiError>) {
        closeResult = result
    }
}
