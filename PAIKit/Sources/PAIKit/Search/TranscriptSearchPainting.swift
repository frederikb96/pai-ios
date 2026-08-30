import Foundation

/// A stretch of text carrying one highlight state, in UTF-16 units relative to the text it was
/// computed from.
public struct TranscriptSearchSegment: Equatable, Sendable {
    public enum Emphasis: Equatable, Sendable {
        case none
        /// Any hit other than the one search is currently on.
        case hit
        /// The hit search has navigated to.
        case currentHit
    }

    public let range: NSRange
    public let emphasis: Emphasis

    public init(range: NSRange, emphasis: Emphasis) {
        self.range = range
        self.emphasis = emphasis
    }
}

/// Splits `[0, length)` into ordered, non-overlapping segments carrying the highlight state that
/// applies to each — the piece a view needs to paint a background over a search hit without
/// inserting anything into the text itself. That property is the whole design this rests on: a
/// row's measured height must never change because a search started, and the web gets the same
/// property from the CSS Custom Highlight API for the same reason (`::highlight()` only ever adds
/// colour, never a layout-affecting attribute).
public enum TranscriptSearchPainting {
    /// `highlights` need not be sorted, clipped to `length`, or non-overlapping on input — a run
    /// boundary and a hit boundary can land anywhere relative to each other, so this does all
    /// three itself. Where two entries do overlap (which a caller should avoid — one occurrence
    /// should appear once, marked current or not), the later one in `highlights` wins for the
    /// overlapping span.
    public static func segments(
        length: Int, highlights: [(range: NSRange, isCurrent: Bool)]
    ) -> [TranscriptSearchSegment] {
        guard length > 0 else { return [] }

        let clipped: [(range: NSRange, isCurrent: Bool)] =
            highlights
            .compactMap { entry in
                let lower = max(0, entry.range.location)
                let upper = min(length, entry.range.location + entry.range.length)
                guard lower < upper else { return nil }
                return (NSRange(location: lower, length: upper - lower), entry.isCurrent)
            }
            .sorted { $0.range.location < $1.range.location }

        var segments: [TranscriptSearchSegment] = []
        var cursor = 0
        for entry in clipped {
            let start = max(cursor, entry.range.location)
            let end = entry.range.location + entry.range.length
            guard end > start else { continue }
            if start > cursor {
                segments.append(
                    TranscriptSearchSegment(range: NSRange(location: cursor, length: start - cursor), emphasis: .none))
            }
            segments.append(
                TranscriptSearchSegment(
                    range: NSRange(location: start, length: end - start), emphasis: entry.isCurrent ? .currentHit : .hit
                )
            )
            cursor = end
        }
        if cursor < length {
            segments.append(
                TranscriptSearchSegment(range: NSRange(location: cursor, length: length - cursor), emphasis: .none))
        }
        return segments
    }
}
