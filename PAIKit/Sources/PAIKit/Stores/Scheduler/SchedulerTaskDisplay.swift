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

    /// Where a task's rhythm is shown: its cadence, `on demand` for a task fired only by hand, or
    /// for a one-time task `once ·` and the instant it fires, in Berlin time. Swift port of
    /// `TaskTable.tsx`'s `When`.
    public static func whenLabel(_ task: ScheduledTask) -> String {
        guard let runAt = task.runAt else { return task.cadence ?? "on demand" }
        guard let date = IsoTimestamp.date(from: runAt) else { return "once · \(runAt)" }
        return "once · " + SchedulerRunDisplay.formatBerlin(ms: Int(date.timeIntervalSince1970 * 1000))
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

    /// A pending `wake_later` wake fires the task outside its schedule, so it is shown beside the
    /// task's own rhythm: `wake 2026-11-12 09:00`, with `(+1)` per further pending wake. `nil` with
    /// none. Swift port of `TaskTable.tsx`'s `WakeMark`.
    public static func wakeLabel(_ task: ScheduledTask) -> String? {
        guard let count = task.pendingWakeCount, count > 0, let next = task.nextWakeAtMs else { return nil }
        let more = count > 1 ? " (+\(count - 1))" : ""
        return "wake " + SchedulerRunDisplay.formatBerlin(ms: next) + more
    }

    /// A debounce in minutes the way a person says it: `45 min`, `2 h`, `1 d 6 h`.
    public static func debounceLabel(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours < 24 { return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min" }
        let days = hours / 24
        return hours % 24 == 0 ? "\(days) d" : "\(days) d \(hours % 24) h"
    }

    /// What a mailbox wake-up is waiting for: `nothing waiting`, or the mail and when it goes out.
    public static func wakeWaitingLabel(_ wake: InboxWake) -> String {
        guard wake.pendingCount > 0, let due = wake.dueAt, let date = IsoTimestamp.date(from: due) else {
            return "nothing waiting"
        }
        let when = SchedulerRunDisplay.formatBerlin(ms: Int(date.timeIntervalSince1970 * 1000))
        return "\(wake.pendingCount) mail\(wake.pendingCount == 1 ? "" : "s") waiting, goes out \(when)"
    }

    /// When the registration last woke its session, or `never woken`.
    public static func wakeLastWokenLabel(_ wake: InboxWake) -> String {
        guard let raw = wake.lastWokenAt, let date = IsoTimestamp.date(from: raw) else { return "never woken" }
        return "last woke " + SchedulerRunDisplay.formatBerlin(ms: Int(date.timeIntervalSince1970 * 1000))
    }
}
