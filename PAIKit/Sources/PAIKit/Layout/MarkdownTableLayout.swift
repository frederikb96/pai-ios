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
    /// One uniform height per row, header included — `table.rows.count + 1`.
    ///
    /// `rowHeight` is already resolved (line height plus cell padding, scaled for the current
    /// Dynamic Type category) by whoever calls this; nothing here knows about typography, so the
    /// same formula serves the real measurer and, later, the view that actually draws the grid.
    public static func height(for table: MarkdownTable, rowHeight: Double) -> Double {
        Double(table.rows.count + 1) * rowHeight
    }
}
