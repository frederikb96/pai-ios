import XCTest

@testable import PAIKit

@MainActor
final class SupervisionStoreTests: XCTestCase {

    private func detail(
        id: String = "sup1", state: SupervisionState = .active, model: String? = nil
    ) -> SupervisionDetail {
        SupervisionDetail(
            id: id, workerSessionId: "s1", taskId: nil, state: state, memo: nil, cursorMessageId: nil,
            model: model, createdAtMs: 0, updatedAtMs: 0)
    }

    // MARK: - load

    func testLoadLeavesDetailNilWhenNoSupervisionExists() async {
        let api = FakeSupervisionApi()
        let store = SupervisionStore(sessionId: "s1", api: api)

        await store.load()

        XCTAssertNil(store.detail)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.needsAttach)
    }

    /// `by-session` answers "is there one at all" cheaply; the full detail — including verdicts,
    /// which that first call never carries — is a second fetch by the supervision's own id.
    func testLoadFetchesTheFullDetailWhenABindingExists() async {
        let api = FakeSupervisionApi()
        await api.setBySessionResult(.success(SupervisionBySessionResponse(supervision: detail())))
        await api.setDetailResult(
            .success(
                SupervisionDetail(
                    id: "sup1", workerSessionId: "s1", taskId: nil, state: .active, memo: "watching",
                    cursorMessageId: nil, createdAtMs: 0, updatedAtMs: 0,
                    verdicts: [
                        SupervisionVerdictSummary(id: "v1", verdict: .ok, reason: nil, tokens: nil, createdAtMs: 0)
                    ])))
        let store = SupervisionStore(sessionId: "s1", api: api)

        await store.load()

        XCTAssertEqual(store.detail?.memo, "watching")
        XCTAssertEqual(store.detail?.verdicts?.count, 1)
        XCTAssertFalse(store.needsAttach)
    }

    func testLoadSurfacesAFailureAsAnErrorMessage() async {
        let api = FakeSupervisionApi()
        await api.setBySessionResult(.failure(.detail("could not reach the server", statusCode: 500)))
        let store = SupervisionStore(sessionId: "s1", api: api)

        await store.load()

        XCTAssertEqual(store.errorMessage, "could not reach the server")
        XCTAssertNil(store.detail)
    }

    /// A detached supervision is not deleted server-side — its row survives with `state ==
    /// .ended`. The backend allows re-attaching and only refuses (409) while one is genuinely
    /// active, so `needsAttach` — not `detail == nil` — is what a view must branch on.
    func testAnEndedSupervisionStillNeedsAttach() async {
        let api = FakeSupervisionApi()
        await api.setBySessionResult(.success(SupervisionBySessionResponse(supervision: detail(state: .ended))))
        await api.setDetailResult(.success(detail(state: .ended)))
        let store = SupervisionStore(sessionId: "s1", api: api)

        await store.load()

        XCTAssertNotNil(store.detail)
        XCTAssertTrue(store.needsAttach)
    }

    /// Re-attaching after a detach starts from the previous configuration rather than a blank
    /// form — the config draft is pre-filled from whatever `load()` fetched, ended or not.
    func testLoadPreFillsTheConfigDraftFromTheFetchedDetail() async {
        let api = FakeSupervisionApi()
        await api.setBySessionResult(
            .success(SupervisionBySessionResponse(supervision: detail(state: .ended, model: "opus"))))
        await api.setDetailResult(.success(detail(state: .ended, model: "opus")))
        let store = SupervisionStore(sessionId: "s1", api: api)

        await store.load()

        XCTAssertEqual(store.config.model, "opus")
    }

    // MARK: - attach

    func testAttachSendsTheCurrentConfigDraftAndStoresWhatComesBack() async {
        let api = FakeSupervisionApi()
        await api.setAttachResult(
            .success(
                Supervision(
                    id: "sup1", workerSessionId: "s1", taskId: nil, state: .active, memo: nil,
                    cursorMessageId: nil, model: "opus", createdAtMs: 0, updatedAtMs: 0)))
        let store = SupervisionStore(sessionId: "s1", api: api)
        store.config = SupervisionConfigFields(model: "opus")

        let ok = await store.attach()

        XCTAssertTrue(ok)
        XCTAssertEqual(store.detail?.model, "opus")
        XCTAssertFalse(store.needsAttach)
        let calls = await api.attachCalls
        XCTAssertEqual(calls.map(\.sessionId), ["s1"])
        XCTAssertEqual(calls.map(\.config.model), ["opus"])
    }

    func testAttachFailureLeavesNoDetailAndSurfacesTheError() async {
        let api = FakeSupervisionApi()
        await api.setAttachResult(.failure(.detail("already supervised", statusCode: 409)))
        let store = SupervisionStore(sessionId: "s1", api: api)

        let ok = await store.attach()

        XCTAssertFalse(ok)
        XCTAssertNil(store.detail)
        XCTAssertEqual(store.errorMessage, "already supervised")
    }

    // MARK: - detach

    /// Detaching reloads rather than clearing `detail` locally — the backend keeps the row
    /// (`ended`), and the reload is what picks that up and flips `needsAttach` back on.
    func testDetachReloadsAndEndsUpNeedingAttachAgain() async {
        let api = FakeSupervisionApi()
        await api.setBySessionResult(.success(SupervisionBySessionResponse(supervision: detail(state: .active))))
        await api.setDetailResult(.success(detail(state: .active)))
        let store = SupervisionStore(sessionId: "s1", api: api)
        await store.load()
        XCTAssertFalse(store.needsAttach)

        // The server now reports the same row as ended, the way it would after a real detach.
        await api.setBySessionResult(.success(SupervisionBySessionResponse(supervision: detail(state: .ended))))
        await api.setDetailResult(.success(detail(state: .ended)))

        let ok = await store.detach()

        XCTAssertTrue(ok)
        XCTAssertTrue(store.needsAttach)
        let calls = await api.deleteCalls
        XCTAssertEqual(calls, ["sup1"])
    }

    /// Nothing to detach — a no-op rather than a call the server would 404 on.
    func testDetachWithNoLoadedDetailDoesNothing() async {
        let api = FakeSupervisionApi()
        let store = SupervisionStore(sessionId: "s1", api: api)

        let ok = await store.detach()

        XCTAssertFalse(ok)
        let calls = await api.deleteCalls
        XCTAssertTrue(calls.isEmpty)
    }
}

extension FakeSupervisionApi {
    func setBySessionResult(_ result: Result<SupervisionBySessionResponse, PaiError>) {
        bySessionResult = result
    }

    func setDetailResult(_ result: Result<SupervisionDetail, PaiError>) {
        detailResult = result
    }

    func setAttachResult(_ result: Result<Supervision, PaiError>) {
        attachResult = result
    }
}
