import Foundation

/// A calendar day with no time of day and no zone, entered and shown as `YYYY-MM-DD` whatever the
/// device's locale prefers. Resolved to instants only through a ``TimeWindow``, against a calendar.
public struct CalendarDay: Sendable, Equatable, Hashable, Comparable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar = TimeWindow.defaultCalendar()) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// Strict `YYYY-MM-DD`: exactly ten characters and a day that exists (no 2026-02-30).
    public init?(isoString text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        let calendar = TimeWindow.defaultCalendar()
        let candidate = CalendarDay(year: year, month: month, day: day)
        guard let date = candidate.startOfDay(in: calendar), CalendarDay(date, calendar: calendar) == candidate
        else { return nil }
        self = candidate
    }

    public var isoString: String {
        Self.padded(year, to: 4) + "-" + Self.padded(month, to: 2) + "-" + Self.padded(day, to: 2)
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public func startOfDay(in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
            .map { calendar.startOfDay(for: $0) }
    }

    /// The last millisecond of the day: `until` bounds are inclusive.
    public func endOfDay(in calendar: Calendar) -> Date? {
        guard let start = startOfDay(in: calendar), let next = calendar.date(byAdding: .day, value: 1, to: start)
        else { return nil }
        return next.addingTimeInterval(-0.001)
    }

    private static func padded(_ value: Int, to width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}

/// The four fixed windows of the time picker's menu. Stored as the preset itself and resolved
/// against "now" every time a query runs, so "Last 7 days" keeps rolling.
public enum TimeWindowPreset: String, Sendable, CaseIterable, Identifiable {
    case today, sinceYesterday, last7Days, last30Days

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .today: return "Today"
        case .sinceYesterday: return "Since yesterday"
        case .last7Days: return "Last 7 days"
        case .last30Days: return "Last 30 days"
        }
    }
}

/// Two stops `0...52` on the slider's fixed axis (the last 52 weeks), `from < to`.
public struct SliderSelection: Sendable, Equatable, Hashable {
    public let from: Int
    public let to: Int

    /// Clamped so the pair is always a valid selection, whatever a drag hands in.
    public init(from: Int, to: Int) {
        let low = min(max(from, 0), TimeWindowSlider.weeks - 1)
        self.from = low
        self.to = min(max(to, low + 1), TimeWindowSlider.weeks)
    }

    public static let full = SliderSelection(from: 0, to: TimeWindowSlider.weeks)
}

/// The window a time picker has applied. `nil` where it is stored means no window.
public enum TimeWindow: Sendable, Equatable, Hashable {
    case preset(TimeWindowPreset)
    case slider(SliderSelection)
    /// Both days inclusive.
    case custom(from: CalendarDay, to: CalendarDay)

    /// Gregorian in the device's zone: `YYYY-MM-DD` must mean the Gregorian date whatever
    /// calendar the user's locale prefers.
    public static func defaultCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// The instants this window means at `now`.
    public func bounds(now: Date, calendar: Calendar = TimeWindow.defaultCalendar()) -> TimeBounds {
        switch self {
        case .preset(.today):
            return TimeBounds(since: calendar.startOfDay(for: now), until: now)
        case .preset(.sinceYesterday):
            let today = calendar.startOfDay(for: now)
            return TimeBounds(since: calendar.date(byAdding: .day, value: -1, to: today), until: now)
        case .preset(.last7Days):
            return TimeBounds(since: now.addingTimeInterval(-7 * 86_400), until: now)
        case .preset(.last30Days):
            return TimeBounds(since: now.addingTimeInterval(-30 * 86_400), until: now)
        case let .slider(selection):
            let since = TimeWindowSlider.date(forStop: selection.from, now: now, calendar: calendar)
            guard selection.to < TimeWindowSlider.weeks else { return TimeBounds(since: since, until: now) }
            let end = TimeWindowSlider.date(forStop: selection.to, now: now, calendar: calendar)
            return TimeBounds(since: since, until: CalendarDay(end, calendar: calendar).endOfDay(in: calendar))
        case let .custom(from, to):
            return TimeBounds(since: from.startOfDay(in: calendar), until: to.endOfDay(in: calendar))
        }
    }

    /// The preset name, `YYYY-MM-DD – YYYY-MM-DD`, or `YYYY-MM-DD – now`.
    public func label(now: Date, calendar: Calendar = TimeWindow.defaultCalendar()) -> String {
        switch self {
        case let .preset(preset):
            return preset.label
        case let .slider(selection):
            let start = TimeWindowSlider.startLabel(selection, now: now, calendar: calendar)
            return start + " – " + TimeWindowSlider.endLabel(selection, now: now, calendar: calendar)
        case let .custom(from, to):
            return from.isoString + " – " + to.isoString
        }
    }

    /// The slider position to reopen the overlay at: the window's own when it is a slider window,
    /// otherwise the whole axis.
    public var sliderSelection: SliderSelection {
        if case let .slider(selection) = self { return selection }
        return .full
    }
}

/// A resolved window: the instants a query is narrowed to, both inclusive.
public struct TimeBounds: Sendable, Equatable {
    public let since: Date?
    public let until: Date?

    public init(since: Date?, until: Date?) {
        self.since = since
        self.until = until
    }

    public func contains(_ date: Date) -> Bool {
        if let since, date < since { return false }
        if let until, date > until { return false }
        return true
    }

    public func contains(epochMilliseconds: Int) -> Bool {
        contains(Date(timeIntervalSince1970: Double(epochMilliseconds) / 1000))
    }

    /// ISO 8601 with an offset, the shape every `since`/`until` parameter takes.
    public static func wireString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'+00:00'"
        return formatter.string(from: date)
    }

    func queryItems(sinceName: String, untilName: String) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let since { items.append(URLQueryItem(name: sinceName, value: Self.wireString(since))) }
        if let until { items.append(URLQueryItem(name: untilName, value: Self.wireString(until))) }
        return items
    }
}

/// A month label's place on the slider axis.
public struct MonthMark: Sendable, Equatable, Identifiable {
    public let stop: Int
    /// `1...12`
    public let month: Int
    public let year: Int
    /// Whether the label also names the year: the axis' first tick and every January.
    public let showsYear: Bool
    public var id: Int { stop }
}

/// The slider's fixed axis: the last 52 weeks at week granularity. Stop `p` is local midnight
/// today minus `(52 - p)` weeks.
public enum TimeWindowSlider {
    public static let weeks = 52

    public static func date(forStop stop: Int, now: Date, calendar: Calendar = TimeWindow.defaultCalendar())
        -> Date
    {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(weeks - stop) * 7, to: today) ?? today
    }

    /// The stop nearest a position along the track (`0...1`).
    public static func stop(forFraction fraction: Double) -> Int {
        let clamped = min(max(fraction, 0), 1)
        return Int((clamped * Double(weeks)).rounded())
    }

    public static func startLabel(
        _ selection: SliderSelection, now: Date, calendar: Calendar = TimeWindow.defaultCalendar()
    ) -> String {
        CalendarDay(date(forStop: selection.from, now: now, calendar: calendar), calendar: calendar).isoString
    }

    /// `now` at the right-hand end of the axis, the date of the stop otherwise.
    public static func endLabel(
        _ selection: SliderSelection, now: Date, calendar: Calendar = TimeWindow.defaultCalendar()
    ) -> String {
        guard selection.to < weeks else { return "now" }
        return CalendarDay(date(forStop: selection.to, now: now, calendar: calendar), calendar: calendar).isoString
    }

    /// Where a month label sits along the axis: the first stop of each month, with the month's
    /// number (`1...12`) for the view to name in the user's language.
    public static func monthMarks(now: Date, calendar: Calendar = TimeWindow.defaultCalendar())
        -> [MonthMark]
    {
        var marks: [MonthMark] = []
        var previous: Int?
        for stop in 0...weeks {
            let parts = calendar.dateComponents(
                [.year, .month], from: date(forStop: stop, now: now, calendar: calendar))
            guard let month = parts.month, let year = parts.year, month != previous else { continue }
            marks.append(
                MonthMark(stop: stop, month: month, year: year, showsYear: marks.isEmpty || month == 1))
            previous = month
        }
        return marks
    }

    /// Moves the start thumb; it can reach the end thumb's stop minus one but never pass it.
    public static func movingStart(of selection: SliderSelection, to stop: Int) -> SliderSelection {
        SliderSelection(from: min(stop, selection.to - 1), to: selection.to)
    }

    /// Moves the end thumb; it can reach the start thumb's stop plus one but never pass it.
    public static func movingEnd(of selection: SliderSelection, to stop: Int) -> SliderSelection {
        SliderSelection(from: selection.from, to: max(stop, selection.from + 1))
    }

    /// Which thumb a touch at `stop` should drag: the nearer one, the start thumb when equally
    /// near and the touch is left of the pair's middle.
    public static func movesStart(touchStop stop: Int, selection: SliderSelection) -> Bool {
        let toStart = abs(stop - selection.from)
        let toEnd = abs(stop - selection.to)
        if toStart != toEnd { return toStart < toEnd }
        return stop <= selection.from
    }
}
