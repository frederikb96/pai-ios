import XCTest

@testable import PAIKit

final class SchedulerTaskDisplayTests: XCTestCase {

    private func task(
        stopped: Bool = false, lastFireAtMs: Int? = nil, lastSuccessAtMs: Int? = nil
    ) -> ScheduledTask {
        ScheduledTask(
            id: "t1", name: "t", enabled: true, environment: "default", workingDir: nil, prompt: "p",
            appendSystemPrompt: nil, cadence: "0 9 * * *", timezone: "UTC", hasGate: false, gateRuntime: nil,
            gateTimeoutSeconds: 30, sessionPolicy: .fresh, sessionId: nil, quietPeriodMinutes: 60,
            supervisionEnabled: false, supervisionModel: nil, hasWebhook: false, stopped: stopped,
            stoppedReason: nil, lastFireAtMs: lastFireAtMs, lastSuccessAtMs: lastSuccessAtMs,
            nextFireAtMs: nil, createdAtMs: 0, updatedAtMs: 0)
    }

    /// `stopped` outranks everything else — a task can be stopped after a run that itself
    /// succeeded, and that must still read as stopped, not "ok."
    func testStoppedOutranksAnOtherwiseSuccessfulLastRun() {
        let t = task(stopped: true, lastFireAtMs: 100, lastSuccessAtMs: 100)
        XCTAssertEqual(SchedulerTaskDisplay.lastRunStatus(t), .stopped)
    }

    func testNeverFiredIsDistinctFromAttention() {
        XCTAssertEqual(SchedulerTaskDisplay.lastRunStatus(task()), .never)
    }

    func testTheLastFireSucceedingReadsAsOk() {
        let t = task(lastFireAtMs: 100, lastSuccessAtMs: 100)
        XCTAssertEqual(SchedulerTaskDisplay.lastRunStatus(t), .ok)
    }

    /// The last fire and the last SUCCESS disagreeing is exactly what "needs attention" means —
    /// something ran since the task last actually succeeded.
    func testALastFireNewerThanTheLastSuccessNeedsAttention() {
        let t = task(lastFireAtMs: 200, lastSuccessAtMs: 100)
        XCTAssertEqual(SchedulerTaskDisplay.lastRunStatus(t), .attention)
    }
}
