import Foundation

/// Each loaded row's measured cards and parsed timestamp, remembered across the passes a live
/// transcript makes over its window.
///
/// The transcript rebuilds its row list from the whole window on every arriving batch and every
/// status change. Planning a row parses its markdown, and looking its blocks up in
/// ``BlockHeightCache`` hashes their full text; the time separators parse two ISO timestamps a
/// row. Done for every row on every pass, that made each arriving message cost more than the one
/// before it for as long as the session stayed open. With this, a pass costs a lookup for each row
/// it has seen and a measurement only for the rows that are new or whose inputs changed.
///
/// A remembered measurement is returned only when the message is equal to the one it was measured
/// from and every input that shapes the row is unchanged — width, measurement environment, which
/// cards are open and whether the row carries a separator. Anything else is measured afresh, so a
/// row can never be laid out at a height measured for something it no longer is. Comparing the
/// message is cheap in the common case: a window keeps the same values from pass to pass, and
/// equal storage compares without reading the text.
///
/// One entry per message id, so the memo holds at most what the window has held since the last
/// ``retain(only:)``.
public final class TranscriptRowMemo {

    /// Everything besides the message itself that a row's measurement depends on.
    public struct Inputs: Equatable {
        public let width: Double
        public let environment: MeasurementEnvironment
        public let revealedCards: Set<Int>
        public let hasTimeSeparator: Bool

        /// `width` is rounded to the point for the same reason ``BlockHeightCache`` rounds it: two
        /// layout passes report one visual width a few ULPs apart, and an exact key would miss on
        /// every pass for a width that never changed.
        public init(width: Double, environment: MeasurementEnvironment, revealedCards: Set<Int>, hasTimeSeparator: Bool)
        {
            self.width = width.rounded()
            self.environment = environment
            self.revealedCards = revealedCards
            self.hasTimeSeparator = hasTimeSeparator
        }
    }

    private struct Entry {
        let message: Message
        let inputs: Inputs
        let cards: [MeasuredCard]
    }

    private struct ParsedTimestamp {
        let raw: String?
        let date: Date?
    }

    private var entries: [Int: Entry] = [:]
    private var timestamps: [Int: ParsedTimestamp] = [:]

    public init() {}

    /// How many rows are remembered — what a caller compares against its window to decide when to
    /// ``retain(only:)``.
    public var count: Int { entries.count }

    /// `message`'s cards under `inputs` — remembered, or produced by `measure` and remembered.
    public func cards(for message: Message, inputs: Inputs, measure: () -> [MeasuredCard]) -> [MeasuredCard] {
        if let entry = entries[message.id], entry.inputs == inputs, entry.message == message {
            return entry.cards
        }
        let cards = measure()
        entries[message.id] = Entry(message: message, inputs: inputs, cards: cards)
        return cards
    }

    /// `message`'s timestamp as a date, parsed once per timestamp string; `nil` when it has none or
    /// it does not parse — the same answer ``IsoTimestamp/date(from:)`` gives.
    public func date(of message: Message) -> Date? {
        if let parsed = timestamps[message.id], parsed.raw == message.timestamp {
            return parsed.date
        }
        let date = message.timestamp.flatMap(IsoTimestamp.date(from:))
        timestamps[message.id] = ParsedTimestamp(raw: message.timestamp, date: date)
        return date
    }

    /// Forgets every message whose id is not in `ids` — what keeps the memo bounded by the window
    /// once rows leave it.
    public func retain(only ids: Set<Int>) {
        entries = entries.filter { ids.contains($0.key) }
        timestamps = timestamps.filter { ids.contains($0.key) }
    }

    public func removeAll() {
        entries.removeAll()
        timestamps.removeAll()
    }
}
