import XCTest

@testable import PAIKit

@MainActor
final class RunHistoryStoreTests: XCTestCase {

    private func run(id: String) -> TaskRun {
        TaskRun(
            id: id, taskId: "t1", trigger: .schedule, disposition: .fired, reason: nil, sessionId: nil,
            gateStdout: nil, gateExitCode: nil, notified: false, startedAtMs: 0, finishedAtMs: nil)
    }

    /// A page exactly at the page size means there might be more — the boundary the pagination
    /// logic actually turns on. A page short of it is the only signal "no more" has.
    func testAFullPageMeansThereMightBeMore() async {
        let api = FakeRunHistoryApi()
        let fullPage = (0..<RunHistoryStore.pageSize).map { run(id: "r\($0)") }
        await api.setPages([.success(SchedulerTaskRunsResponse(runs: fullPage, nextOffset: nil))])
        let store = RunHistoryStore(taskId: "t1", api: api)

        await store.loadMore()

        XCTAssertTrue(store.hasMore)
        XCTAssertEqual(store.runs.count, RunHistoryStore.pageSize)
    }

    func testAPartialPageMeansThereIsNoMore() async {
        let api = FakeRunHistoryApi()
        let partialPage = [run(id: "r0"), run(id: "r1")]
        await api.setPages([.success(SchedulerTaskRunsResponse(runs: partialPage, nextOffset: nil))])
        let store = RunHistoryStore(taskId: "t1", api: api)

        await store.loadMore()

        XCTAssertFalse(store.hasMore)
    }

    /// Three fires deep, not one — the ordering claim (offset advancing rather than resetting)
    /// only means something across more than a single page.
    func testSuccessivePagesAppendRatherThanReplace() async {
        let api = FakeRunHistoryApi()
        let fullPage = (0..<RunHistoryStore.pageSize).map { run(id: "a\($0)") }
        let secondPage = [run(id: "b0"), run(id: "b1")]
        await api.setPages(
            [
                .success(SchedulerTaskRunsResponse(runs: fullPage, nextOffset: nil)),
                .success(SchedulerTaskRunsResponse(runs: secondPage, nextOffset: nil)),
            ])
        let store = RunHistoryStore(taskId: "t1", api: api)

        await store.loadMore()
        await store.loadMore()

        XCTAssertEqual(store.runs.map(\.id), fullPage.map(\.id) + secondPage.map(\.id))
        let calls = await api.calls
        XCTAssertEqual(calls.map(\.offset), [0, RunHistoryStore.pageSize])
    }

    /// Once a partial page has said "no more," a further call must not re-ask the server —
    /// exactly the guard `hasMore` exists to be.
    func testLoadMoreIsANoOpOnceThereIsNoMore() async {
        let api = FakeRunHistoryApi()
        await api.setPages([.success(SchedulerTaskRunsResponse(runs: [run(id: "r0")], nextOffset: nil))])
        let store = RunHistoryStore(taskId: "t1", api: api)
        await store.loadMore()
        XCTAssertFalse(store.hasMore)

        await store.loadMore()

        let calls = await api.calls
        XCTAssertEqual(calls.count, 1, "a second call reached the server after hasMore had already gone false")
    }

    func testFailureSurfacesAsAnErrorMessageWithoutClearingAlreadyLoadedRuns() async {
        let api = FakeRunHistoryApi()
        // A full first page so `hasMore` stays true and the second `loadMore()` actually reaches
        // the server rather than being refused by the guard the previous test covers.
        let fullPage = (0..<RunHistoryStore.pageSize).map { run(id: "r\($0)") }
        await api.setPages(
            [
                .success(SchedulerTaskRunsResponse(runs: fullPage, nextOffset: nil)),
                .failure(.detail("could not reach the server", statusCode: 500)),
            ])
        let store = RunHistoryStore(taskId: "t1", api: api)
        await store.loadMore()

        await store.loadMore()

        XCTAssertEqual(store.errorMessage, "could not reach the server")
        XCTAssertEqual(
            store.runs.count, fullPage.count, "a failed later page dropped the rows already loaded")
    }
}
