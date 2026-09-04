import Foundation

/// Where a jump lands when its own target id has no row at all in the loaded window.
///
/// A boundary id (`min(id)` of the session, or a `system`/`compact` row) can route
/// `.hidden`/`.none` (`MessageRouting.route`'s own gap: a legacy caveat wrapper, or a type this
/// client does not recognise), which drops it from `TranscriptRowPlan.cards(for:isExpanded:)` and
/// therefore from the row list entirely — a target id that is genuinely loaded but still has no
/// row to scroll to. The web never hits this: every message keeps a wrapper element in the DOM
/// regardless of what it renders (`TranscriptRow.tsx`'s own "it never leaves the DOM"), so an id
/// always has *something* to scroll to there.
public enum TranscriptLanding {
    /// `target` itself when it has a row; otherwise the first loaded row past it, so a target
    /// with nothing of its own still lands the reader just after where it would have been rather
    /// than not moving at all. `nil` only when nothing loaded sits at or past `target` — every
    /// candidate is behind it, which a caller should treat the same as "not found".
    ///
    /// `rowIds` must already be ascending, the same order `TranscriptLayout.Row`/the collection
    /// view's own `rows` are always kept in — this performs no sorting of its own.
    public static func rowId(forTarget target: Int, in rowIds: [Int]) -> Int? {
        if rowIds.contains(target) { return target }
        return rowIds.first { $0 > target }
    }
}
