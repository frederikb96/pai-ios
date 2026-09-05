import XCTest

@testable import PAIKit

@MainActor
final class SupervisionStoreTests: XCTestCase {

    private func detail(id: String = "sup1", state: SupervisionState = .active) -> SupervisionDetail {
        SupervisionDetail(
            id: id, workerSessionId: "s1", taskId: nil, state: state, memo: nil, cursorMessageId: nil,
            createdAtMs: 0, updatedAtMs: 0)
    }

    // MARK: - load

    func testLoadLeavesDetailNilWhenNoSupervisionExists() async {
        let api = FakeSupervisionApi()
        let store = SupervisionStore(sessionId: "s1", api: api)

        await store.load()

        XCTAssertNil(store.detail)
        XCTAssertNil(store.errorMessage)
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
    }

    func testLoadSurfacesAFailureAsAnErrorMessage() async {
        let api = FakeSupervisionApi()
        await api.setBySessionResult(.failure(.detail("could not reach the server", statusCode: 500)))
        let store = SupervisionStore(sessionId: "s1", api: api)

        await store.load()

        XCTAssertEqual(store.errorMessage, "could not reach the server")
        XCTAssertNil(store.detail)
    }

    // MARK: - attach

    func testAttachStoresWhatComesBackAndSendsTheChosenModel() async {
        let api = FakeSupervisionApi()
        await api.setAttachResult(
            .success(
                Supervision(
                    id: "sup1", workerSessionId: "s1", taskId: nil, state: .active, memo: nil,
                    cursorMessageId: nil, model: "opus", createdAtMs: 0, updatedAtMs: 0)))
        let store = SupervisionStore(sessionId: "s1", api: api)

        let ok = await store.attach(model: "opus")

        XCTAssertTrue(ok)
        XCTAssertEqual(store.detail?.model, "opus")
        let calls = await api.attachCalls
        XCTAssertEqual(calls.map(\.sessionId), ["s1"])
        XCTAssertEqual(calls.map(\.model), ["opus"])
    }

    func testAttachFailureLeavesNoDetailAndSurfacesTheError() async {
        let api = FakeSupervisionApi()
        await api.setAttachResult(.failure(.detail("already supervised", statusCode: 409)))
        let store = SupervisionStore(sessionId: "s1", api: api)

        let ok = await store.attach(model: nil)

        XCTAssertFalse(ok)
        XCTAssertNil(store.detail)
        XCTAssertEqual(store.errorMessage, "already supervised")
    }

    // MARK: - detach

    func testDetachClearsTheDetailOnSuccess() async {
        let api = FakeSupervisionApi()
        await api.setBySessionResult(.success(SupervisionBySessionResponse(supervision: detail())))
        await api.setDetailResult(.success(detail()))
        let store = SupervisionStore(sessionId: "s1", api: api)
        await store.load()
        XCTAssertNotNil(store.detail)

        let ok = await store.detach()

        XCTAssertTrue(ok)
        XCTAssertNil(store.detail)
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
