import Foundation

/// Pure display logic shared by the task list and its own row — kept out of the view so it is
/// provable on Linux. Swift port of `schedulerModel.ts`.
public enum SchedulerTaskDisplay {
    public enum LastRunStatus: Equatable, Sendable {
        case never, ok, attention, stopped
    }

    /// What actually happened to the task's last run, from `lastRun` — the same shape the
    /// run-history list gives one run, computed at read time rather than a status the task
    /// itself holds. Replaces the old `lastFireAtMs`/`lastSuccessAtMs` proxy, which read a fire
    /// that had merely STARTED as a success regardless of how it ended (a budget stop, above
    /// all). Swift port of `TaskTable.tsx`'s `lastRunStatus` — kept to this same four-word
    /// vocabulary rather than a full disposition badge: `declined`/`skipped`/`deferred` are the
    /// scheduler working as designed, not a health signal, so they read as `.ok` here; only a
    /// hard `refused`/`error`, or a `fired` run that passed a runtime/token warning (and so may
    /// have been stopped), earns `.attention`.
    public static func lastRunStatus(_ task: ScheduledTask) -> LastRunStatus {
        if task.stopped { return .stopped }
        guard let run = task.lastRun else { return .never }
        if run.disposition == .refused || run.disposition == .error { return .attention }
        if run.disposition == .fired && (run.runtimeWarned || run.budgetWarned) { return .attention }
        return .ok
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
