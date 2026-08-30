import Foundation

/// The height of a rendered GFM table — and, deliberately, nothing about its width.
///
/// A table cell never wraps, mirroring the web client: `MarkdownContent.tsx` gives a `<table>` its
/// own horizontal scroll container rather than letting a wide table reflow (see row 25's markdown
/// notes — "a wide table is otherwise cut off at the bubble edge with nothing to scroll"). That
/// choice is what makes this pure arithmetic instead of a text layout: a row's height is the same
/// regardless of the width it is measured at, so a table is the one block a real ``BlockMeasuring``
/// conformance never has to hand to TextKit — and the one case this package can prove completely
/// rather than only compose around a stub.
public enum MarkdownTableLayout {
    /// One uniform text height per row, header included — `table.rows.count + 1` — plus the
    /// spacing `GfmTableView`'s `Grid` puts between every adjacent row (the divider row counted
    /// among them) and the divider's own thickness.
    ///
    /// `rowHeight`, `rowSpacing` and `dividerHeight` are already resolved by whoever calls this;
    /// nothing here knows about typography, so the same formula serves the real measurer and,
    /// later, the view that actually draws the grid. `rowSpacing`/`dividerHeight` default to zero
    /// rather than being required, so a caller measuring only the text-row boundary (as the
    /// existing tests do) needn't resolve chrome it isn't asking about.
    public static func height(
        for table: MarkdownTable, rowHeight: Double, rowSpacing: Double = 0, dividerHeight: Double = 0
    ) -> Double {
        let rowCount = table.rows.count + 1
        // Gaps: one before every text row and one before the divider row between header and
        // data — `rowCount` of them, not `rowCount - 1`, because the divider is itself a row the
        // grid puts a gap before.
        let gaps = Double(rowCount) * rowSpacing
        return Double(rowCount) * rowHeight + gaps + dividerHeight
    }
}
