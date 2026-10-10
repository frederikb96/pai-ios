import XCTest

@testable import PAIKit

@MainActor
final class SchedulerRunInsightsTests: XCTestCase {

    // MARK: wire shape — keys copied from what the backend serialises

    func testRunDecodesTheInsightFieldsFromTheWire() async throws {
        let json = """
            {"id":"r1","task_id":"t1","trigger":"schedule","disposition":"fired","reason":null,
             "session_id":"s1","gate_stdout":null,"gate_exit_code":null,"gate_skipped":false,
             "runtime_warned":false,"budget_warned":false,"started_at_ms":1000,"finished_at_ms":253000,
             "started_at":"1970-01-01T00:00:01+00:00","finished_at":"1970-01-01T00:04:13+00:00",
             "duration_ms":252000,"tokens_start":120000,"tokens_end":340000,
             "tokens_absolute":340000,"tokens_relative":220000,"notified":true}
            """
        let run = try JSONDecoder().decode(TaskRun.self, from: Data(json.utf8))
        XCTAssertEqual(run.durationMs, 252_000)
        XCTAssertEqual([run.tokensStart, run.tokensEnd], [120_000, 340_000])
        XCTAssertEqual([run.tokensAbsolute, run.tokensRelative], [340_000, 220_000])
        XCTAssertTrue(run.notified)
        XCTAssertEqual(run.startedAt, "1970-01-01T00:00:01+00:00")
    }

    func testInsightsDecodeFromTheWire() async throws {
        let json = """
            {"days":7,"since_ms":5,"totals":{"runs":12,"tokens_absolute":3400000,
             "tokens_relative":1200000,"run_seconds":3720.5,"notified":2},
             "tasks":[{"task_id":"t9","name":"Inbox","runs":8,"tokens_absolute":2000000,
             "tokens_relative":900000,"run_seconds":2400.0}]}
            """
        let insights = try JSONDecoder().decode(SchedulerInsights.self, from: Data(json.utf8))
        XCTAssertEqual(insights.totals.tokensRelative, 1_200_000)
        XCTAssertEqual(insights.tasks.first?.taskId, "t9")
        XCTAssertEqual(insights.tasks.first?.runSeconds, 2400.0)
    }

    // MARK: paging

    private func run(id: String) -> TaskRun {
        TaskRun(
            id: id, taskId: "t1", trigger: .schedule, disposition: .fired, reason: nil, sessionId: nil,
            gateStdout: nil, gateExitCode: nil, runtimeWarned: false, budgetWarned: false,
            startedAtMs: 0, finishedAtMs: nil)
    }

    func testAFullPageThatIsTheWholeHistoryEndsPaging() async {
        let api = FakeRunHistoryApi()
        let page = (0..<RunHistoryStore.pageSize).map { run(id: "r\($0)") }
        await api.setPages([
            .success(SchedulerTaskRunsResponse(runs: page, total: RunHistoryStore.pageSize, nextOffset: nil))
        ])
        let store = RunHistoryStore(taskId: "t1", api: api)

        await store.loadMore()

        XCTAssertFalse(store.hasMore)
        XCTAssertEqual(store.total, RunHistoryStore.pageSize)
    }

    func testOnlyRowsNearTheEndStartTheNextPage() async {
        let api = FakeRunHistoryApi()
        let page = (0..<RunHistoryStore.pageSize).map { run(id: "r\($0)") }
        await api.setPages([
            .success(SchedulerTaskRunsResponse(runs: page, total: 5000, nextOffset: nil))
        ])
        let store = RunHistoryStore(taskId: "t1", api: api)
        await store.loadMore()

        XCTAssertFalse(store.shouldLoadMore(onAppearing: page[0]))
        XCTAssertFalse(store.shouldLoadMore(onAppearing: page[RunHistoryStore.pageSize - RunHistoryStore.loadAheadRows - 1]))
        XCTAssertTrue(store.shouldLoadMore(onAppearing: page[RunHistoryStore.pageSize - RunHistoryStore.loadAheadRows]))
        XCTAssertTrue(store.shouldLoadMore(onAppearing: page[RunHistoryStore.pageSize - 1]))
    }

    // MARK: display

    func testBerlinTimeFollowsDaylightSaving() async {
        // 10:00 UTC: CEST (+2) in July, CET (+1) in January.
        XCTAssertEqual(SchedulerRunDisplay.formatBerlin(ms: 1_782_900_000_000), "2026-07-01 12:00")
        XCTAssertEqual(SchedulerRunDisplay.formatBerlin(ms: 1_768_039_200_000), "2026-01-10 11:00")
    }

    func testEndShowsTheDateOnlyWhenTheDayChanges() async {
        let start = 1_782_900_000_000
        XCTAssertEqual(SchedulerRunDisplay.formatBerlinEnd(ms: start + 252_000, sinceMs: start), "12:04")
        XCTAssertEqual(
            SchedulerRunDisplay.formatBerlinEnd(ms: start + 86_400_000, sinceMs: start), "2026-07-02 12:00")
    }

    func testTokenAndDurationFormats() async {
        XCTAssertEqual(SchedulerRunDisplay.formatTokens(nil), "—")
        XCTAssertEqual(SchedulerRunDisplay.formatTokens(870), "870")
        XCTAssertEqual(SchedulerRunDisplay.formatTokens(1_200), "1.2k")
        XCTAssertEqual(SchedulerRunDisplay.formatTokens(340_000), "340k")
        XCTAssertEqual(SchedulerRunDisplay.formatTokens(3_400_000), "3.4M")
        XCTAssertEqual(SchedulerRunDisplay.formatDuration(ms: 45_000), "45s")
        XCTAssertEqual(SchedulerRunDisplay.formatDuration(ms: 252_000), "4m 12s")
        XCTAssertEqual(SchedulerRunDisplay.formatDuration(ms: 7_500_000), "2h 05m")
    }
}
