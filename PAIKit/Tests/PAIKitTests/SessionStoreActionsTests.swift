import XCTest
@testable import PAIKit

/// `SessionActionsStore` is mostly one mutation shape repeated (call the endpoint, write the
/// result back into `SessionListStore`) — these tests target the two places that shape can
/// silently break: a successful mutation must reach the list, and a failed one must never
/// silently swallow its error or write a stale row over a real one. `closeInBackground` gets its
/// own tests because it is the one mutation that delegates to `SessionListStore` entirely rather
/// than mutating through this store's own `api` — see `SessionStoreListStoreTests`'s `closeSession`
/// section for the mutation itself (fire-and-forget, a status field rather than a thrown error).
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

    /// `closeInBackground` goes through the list store exactly the way `deleteNow()` does for
    /// delete — the row belongs to `SessionListStore`, so it is the one that owns writing a close
    /// result back into it, not the actions API this store otherwise mutates through.
    func testCloseInBackgroundDelegatesToTheListStoreRatherThanCallingTheApiDirectly() async {
        let (listStore, listApi) = await makeListStore(session: SessionFixture.make(id: "s1", state: .ready))
        await listStore.loadInitialSessions()
        let actionsApi = FakeSessionActionsApi()
        let store = SessionActionsStore(sessionId: "s1", sessionList: listStore, api: actionsApi)
        let toasts = ToastCenter()

        store.closeInBackground(toasts: toasts)

        let deadline = ContinuousClock().now + .seconds(5)
        while await listApi.closeSessionCalls.isEmpty, ContinuousClock().now < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let calls = await listApi.closeSessionCalls
        XCTAssertEqual(calls, ["s1"])
    }

    /// The failure path this store adds on top of `SessionListStore.closeSession`: a `close_error`
    /// becomes a toast rather than `errorMessage`, since by the time it can happen the sheet that
    /// asked for this has already dismissed and there is nowhere inline left to show it.
    func testCloseInBackgroundShowsAToastOnFailure() async {
        let (listStore, listApi) = await makeListStore(session: SessionFixture.make(id: "s1", state: .ready))
        await listStore.loadInitialSessions()
        await listApi.setCloseSessionResult(.success(CloseResponse(status: .closeError, detail: "agent unreachable")))
        let actionsApi = FakeSessionActionsApi()
        let store = SessionActionsStore(sessionId: "s1", sessionList: listStore, api: actionsApi)
        let toasts = ToastCenter()

        store.closeInBackground(toasts: toasts)

        let deadline = ContinuousClock().now + .seconds(5)
        while toasts.toasts.isEmpty, ContinuousClock().now < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(toasts.toasts.first?.text, "agent unreachable")
        XCTAssertEqual(toasts.toasts.first?.kind, .error)
        XCTAssertNotNil(
            toasts.toasts.first?.action, "a close failure with nowhere inline to retry needs a Retry action")
    }

    /// The Retry action must re-fire the same close rather than merely dismissing — proven by
    /// actually invoking the handler, not by inspecting its label.
    func testCloseInBackgroundToastRetryActionFiresAnotherClose() async {
        let (listStore, listApi) = await makeListStore(session: SessionFixture.make(id: "s1", state: .ready))
        await listStore.loadInitialSessions()
        await listApi.setCloseSessionResult(.success(CloseResponse(status: .closeError, detail: "agent unreachable")))
        let actionsApi = FakeSessionActionsApi()
        let store = SessionActionsStore(sessionId: "s1", sessionList: listStore, api: actionsApi)
        let toasts = ToastCenter()
        store.closeInBackground(toasts: toasts)
        let firstToastDeadline = ContinuousClock().now + .seconds(5)
        while toasts.toasts.isEmpty, ContinuousClock().now < firstToastDeadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        guard let action = toasts.toasts.first?.action else {
            XCTFail("expected a Retry action on the failure toast")
            return
        }

        action.handler()

        let deadline = ContinuousClock().now + .seconds(5)
        while (await listApi.closeSessionCalls).count < 2, ContinuousClock().now < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let calls = await listApi.closeSessionCalls
        XCTAssertEqual(calls, ["s1", "s1"], "Retry must fire the close again rather than only dismissing the toast")
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
}
