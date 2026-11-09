import XCTest

@testable import PAIKit

final class SchedulerTaskDisplayTests: XCTestCase {

    private func task(stopped: Bool = false, lastRun: TaskRun? = nil) -> ScheduledTask {
        ScheduledTask(
            id: "t1", name: "t", enabled: true, environment: "home", workingDir: nil, prompt: "p",
            appendSystemPrompt: nil, cadence: "0 9 * * *", timezone: "UTC", hasGate: false, gateRuntime: nil,
            gateTimeoutSeconds: 30, sessionPolicy: .fresh, sessionId: nil, quietPeriodMinutes: 60,
            supervisionEnabled: false, supervisionModel: nil, stopped: stopped,
            stoppedReason: nil, lastFireAtMs: nil, lastSuccessAtMs: nil,
            nextFireAtMs: nil, createdAtMs: 0, updatedAtMs: 0, lastRun: lastRun)
    }

    private func run(
        disposition: TaskRunDisposition = .fired, runtimeWarned: Bool = false, budgetWarned: Bool = false
    ) -> TaskRun {
        TaskRun(
            id: "r1", taskId: "t1", trigger: .schedule, disposition: disposition, reason: nil,
            sessionId: nil, gateStdout: nil, gateExitCode: nil, runtimeWarned: runtimeWarned,
            budgetWarned: budgetWarned, startedAtMs: 100, finishedAtMs: 200)
    }

    /// `stopped` outranks everything else — a task can be stopped after a run that itself
    /// succeeded, and that must still read as stopped, not "ok."
    func testStoppedOutranksAnOtherwiseSuccessfulLastRun() {
        let t = task(stopped: true, lastRun: run(disposition: .fired))
        XCTAssertEqual(SchedulerTaskDisplay.lastRunStatus(t), .stopped)
    }

    func testNeverFiredIsDistinctFromAttention() {
        XCTAssertEqual(SchedulerTaskDisplay.lastRunStatus(task()), .never)
    }

    func testTheLastFireSucceedingReadsAsOk() {
        let t = task(lastRun: run(disposition: .fired))
        XCTAssertEqual(SchedulerTaskDisplay.lastRunStatus(t), .ok)
    }

    /// The bug this guards: `lastFireAtMs`/`lastSuccessAtMs` are both stamped the moment a fire
    /// STARTS, so a run the budget module later force-stopped used to read as a plain "ok."
    func testAFiredRunThatPassedABudgetWarningNeedsAttention() {
        let t = task(lastRun: run(disposition: .fired, budgetWarned: true))
        XCTAssertEqual(SchedulerTaskDisplay.lastRunStatus(t), .attention)
    }

    func testASchedulerFailureNeedsAttention() {
        let t = task(lastRun: run(disposition: .error))
        XCTAssertEqual(SchedulerTaskDisplay.lastRunStatus(t), .attention)
    }

    /// A gate decline is the scheduler working as designed, not a failure.
    func testAGateDeclineReadsAsOk() {
        let t = task(lastRun: run(disposition: .declined))
        XCTAssertEqual(SchedulerTaskDisplay.lastRunStatus(t), .ok)
    }

    func testAMailboxWakeUpDecodesFromTheWireAndSaysWhatIsWaiting() throws {
        let json = """
            {"wakes": [{"id": "w1", "session_id": "s1", "session_title": null, "inbox": "github",
            "subject_pattern": "Issue", "sender_pattern": null, "prompt": "Look", "debounce_minutes": 90,
            "pending_count": 2, "due_at": "2026-11-09T10:00:00+00:00",
            "delivered_through": "2026-11-09T08:00:00+00:00", "last_woken_at": null,
            "created_at": "2026-11-08T08:00:00+00:00"}]}
            """
        let wake = try JSONDecoder().decode(InboxWakeListResponse.self, from: Data(json.utf8)).wakes[0]

        XCTAssertEqual(wake.pendingCount, 2)
        XCTAssertEqual(SchedulerTaskDisplay.wakeWaitingLabel(wake), "2 mails waiting, goes out 2026-11-09 11:00")
        XCTAssertEqual(SchedulerTaskDisplay.wakeLastWokenLabel(wake), "never woken")
        XCTAssertEqual(SchedulerTaskDisplay.debounceLabel(minutes: wake.debounceMinutes), "1 h 30 min")
    }

    func testATaskWithPendingWakesShowsTheSoonestAndHowManyMore() throws {
        let json = """
            {"id": "t1", "name": "t", "enabled": false, "environment": "home", "working_dir": null,
            "prompt": "p", "append_system_prompt": null, "cadence": null, "timezone": "UTC",
            "has_gate": false, "gate_runtime": null, "gate_timeout_seconds": 30,
            "session_policy": "fresh", "session_id": null, "quiet_period_minutes": 60,
            "supervision_enabled": false, "supervision_model": null, "stopped": false,
            "stopped_reason": null, "last_fire_at_ms": null, "last_success_at_ms": null,
            "next_fire_at_ms": null, "created_at_ms": 0, "updated_at_ms": 0, "last_run": null,
            "pending_wake_count": 2, "next_wake_at_ms": 1794470400000}
            """
        let t = try JSONDecoder().decode(ScheduledTask.self, from: Data(json.utf8))

        XCTAssertEqual(SchedulerTaskDisplay.wakeLabel(t), "wake 2026-11-12 09:00 (+1)")
        XCTAssertNil(SchedulerTaskDisplay.wakeLabel(task()))
    }
}
