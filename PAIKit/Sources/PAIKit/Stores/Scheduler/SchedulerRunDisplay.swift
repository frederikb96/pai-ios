import Foundation

/// How the scheduler's per-run figures read on screen — a Swift port of the formatters in
/// `schedulerModel.ts`, so a run reads the same on both clients.
public enum SchedulerRunDisplay {
    private static let berlin = TimeZone(identifier: "Europe/Berlin") ?? .gmt

    private static func berlinStamp(ms: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = berlin
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// `2026-10-10 14:03` in Europe/Berlin — stored instants are UTC, shown here.
    public static func formatBerlin(ms: Int) -> String { berlinStamp(ms: ms) }

    /// The time of day alone when `ms` falls on the same Berlin day as `sinceMs`, the full stamp
    /// otherwise — a run's end next to its start.
    public static func formatBerlinEnd(ms: Int, sinceMs: Int) -> String {
        let full = berlinStamp(ms: ms)
        return full.prefix(10) == berlinStamp(ms: sinceMs).prefix(10) ? String(full.dropFirst(11)) : full
    }

    /// `1.2M`, `340k`, `870` — token counts run from tens to millions.
    public static func formatTokens(_ n: Int?) -> String {
        guard let n else { return "—" }
        let magnitude = abs(n)
        if magnitude >= 1_000_000 {
            return String(format: magnitude >= 10_000_000 ? "%.0fM" : "%.1fM", Double(n) / 1_000_000)
        }
        if magnitude >= 1_000 {
            return String(format: magnitude >= 10_000 ? "%.0fk" : "%.1fk", Double(n) / 1_000)
        }
        return String(n)
    }

    /// `45s`, `4m 12s`, `2h 05m`.
    public static func formatDuration(ms: Int?) -> String {
        guard let ms else { return "—" }
        let total = Int((Double(ms) / 1000).rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return String(format: "%dm %02ds", minutes, total % 60) }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }
}
