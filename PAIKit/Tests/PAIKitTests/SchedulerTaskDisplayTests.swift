import XCTest

@testable import PAIKit

final class SchedulerTaskDisplayTests: XCTestCase {

    private func task(stopped: Bool = false, lastRun: TaskRun? = nil) -> ScheduledTask {
        ScheduledTask(
            id: "t1", name: "t", enabled: true, environment: "default", workingDir: nil, prompt: "p",
            appendSystemPrompt: nil, cadence: "0 9 * * *", timezone: "UTC", hasGate: false, gateRuntime: nil,
            gateTimeoutSeconds: 30, sessionPolicy: .fresh, sessionId: nil, quietPeriodMinutes: 60,
            supervisionEnabled: false, supervisionModel: nil, hasWebhook: false, stopped: stopped,
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
}
