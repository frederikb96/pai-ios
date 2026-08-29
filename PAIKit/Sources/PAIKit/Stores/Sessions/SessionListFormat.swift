import Foundation

/// Swift port of the parts of `pai-cloud/web/src/utils/format.ts` the session list needs, plus
/// the row's title fallback chain from `Sidebar.tsx`'s `SessionItem`. `formatTime`/recording/
/// duration formatting stay unported — they belong to the transcript and voice screens, neither
/// of which reads through this store.
public enum SessionListFormat {

    /// `>= 1_000_000` as `"X.Ym"`, `>= 1_000` as `"Xk"`, else the raw number.
    public static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fm", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return "\(Int((Double(count) / 1_000).rounded()))k"
        }
        return String(count)
    }

    /// Truncates to `maxLength` characters, appending `"..."` only when it actually did.
    public static func truncate(_ text: String, maxLength: Int) -> String {
        if text.count <= maxLength { return text }
        return String(text.prefix(maxLength)) + "..."
    }

    /// Last path segment of a working directory — `"/home/frederik/Programming/pai-cloud"` ->
    /// `"pai-cloud"`. A path is never empty in practice (every browsable directory is absolute),
    /// so unlike the JS this does not special-case the empty string.
    public static func basename(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let lastSlash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: lastSlash)...])
    }

    /// The row's title: `title ?? truncate(initial_message ?? basename(working_dir) ?? "New
    /// Session", 40)` (`Sidebar.tsx`'s `SessionItem`). The common case for an older, discovered
    /// conversation — most have neither a title nor an initial message.
    public static func displayTitle(for session: Session) -> String {
        if let title = session.title { return title }
        let fallback = session.initialMessage ?? session.workingDir.map(basename) ?? "New Session"
        return truncate(fallback, maxLength: 40)
    }

    /// Which of the three date buckets `formatSessionTime` renders a timestamp into — "today"
    /// shows a bare time, "this week" adds the weekday, anything older shows the date. The
    /// classification is what a unit test can pin down; the actual locale-formatted string (which
    /// bucket becomes which `DateFormatter` template) is left to the view.
    public enum TimeBucket: Sendable, Equatable {
        case today, thisWeek, older
    }

    public static func timeBucket(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> TimeBucket {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        return now.timeIntervalSince(date) < 7 * 86400 ? .thisWeek : .older
    }
}
