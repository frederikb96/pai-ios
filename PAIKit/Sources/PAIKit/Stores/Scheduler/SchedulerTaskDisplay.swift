import Foundation

/// Pure display logic shared by the task list and its own row — kept out of the view so it is
/// provable on Linux. Swift port of `schedulerModel.ts`.
public enum SchedulerTaskDisplay {
    public enum LastRunStatus: Equatable, Sendable {
        case never, ok, attention, stopped
    }

    /// A proxy for "how did the last fire go", built from the two timestamps a task actually
    /// carries — there is no per-task last-disposition field on the wire, only on each individual
    /// `TaskRun`.
    public static func lastRunStatus(_ task: ScheduledTask) -> LastRunStatus {
        if task.stopped { return .stopped }
        if task.lastFireAtMs == nil { return .never }
        return task.lastSuccessAtMs == task.lastFireAtMs ? .ok : .attention
    }

    /// A cadence fires at most once per interval it implies; a task heard from less recently than
    /// a few multiples of that is the one thing that tells a watcher that found nothing from one
    /// that silently died. Five-field cron has no closed-form period, so this is deliberately not
    /// a real cron parser — good enough to catch "has not run in days."
    private static let staleMultiple = 3
    private static let minStaleWindowMs: Int = 60 * 60 * 1000

    public static func isStale(_ task: ScheduledTask, nowMs: Int) -> Bool {
        guard task.enabled, task.cadence != nil, !task.stopped else { return false }
        guard let lastSuccessAtMs = task.lastSuccessAtMs else {
            // Never succeeded — only stale once it has plausibly had the chance to.
            return nowMs - task.createdAtMs > minStaleWindowMs * staleMultiple
        }
        let sinceCreated: Int
        if let next = task.nextFireAtMs, let last = task.lastFireAtMs {
            sinceCreated = max(next - last, minStaleWindowMs)
        } else {
            sinceCreated = minStaleWindowMs
        }
        return nowMs - lastSuccessAtMs > sinceCreated * staleMultiple
    }
}
