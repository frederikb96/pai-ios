import Foundation

/// When the transcript shows a time, now that no row carries one of its own.
///
/// A per-row time gutter costs its width on every row of every screen to answer a question a
/// reader asks a handful of times a session. A separator answers the same question where it is
/// actually being asked — at the seam between one stretch of work and the next — and gives the
/// width back to the content.
///
/// The decision is a pure function of two timestamps so it can be proven on Linux, and so that the
/// same pair always produces the same answer: a row's height depends on it, and a predicate that
/// could answer differently on two passes over the same data is a row that changes height under
/// the reader.
public enum TranscriptTimeSeparator {

    /// What a row shows above itself, if anything.
    public enum Style: Equatable, Sendable {
        case none
        /// A clock time alone — the same day, after a long enough pause.
        case time
        /// The date as well, because the day changed.
        case dateAndTime
    }

    /// The pause that earns a separator. Short enough that a session picked up after a break is
    /// marked, long enough that a burst of tool calls never is.
    public static let quietInterval: TimeInterval = 15 * 60

    /// `previous` is the row immediately above in the loaded window, or `nil` at the top of it.
    ///
    /// The top of the window always shows one: a reader who has scrolled up to the oldest loaded
    /// row is exactly the reader asking when this was. That it may resolve to `.none` once an
    /// older page arrives above it is deliberate and safe — the layout compensates by the distance
    /// the anchor row moved, so any height change above the reader, including this one, is
    /// absorbed rather than seen.
    public static func style(previous: Date?, current: Date?) -> Style {
        guard let current else { return .none }
        guard let previous else { return .dateAndTime }
        if !Calendar.current.isDate(previous, inSameDayAs: current) { return .dateAndTime }
        return current.timeIntervalSince(previous) >= quietInterval ? .time : .none
    }

    /// The same decision taken straight from the wire, for a caller walking a list of messages.
    public static func style(previousTimestamp: String?, currentTimestamp: String?) -> Style {
        style(
            previous: previousTimestamp.flatMap(IsoTimestamp.date(from:)),
            current: currentTimestamp.flatMap(IsoTimestamp.date(from:)))
    }
}
