import XCTest

@testable import PAIKit

/// `MarkdownTableLayout`'s row-spacing and divider-height arithmetic — the part of a GFM table's
/// measured height that used to be folded into a single "row height plus padding" number
/// (`TextKitBlockMeasurer`'s old `tableRowVerticalPadding`), which the report that led to this
/// file found over-measured a real `Grid(verticalSpacing:)` layout by roughly 6pt a row. Every
/// expected value below is a **literal**, not `TranscriptRowMetrics.tableRowSpacing` or
/// `.tableDividerHeight`, so a regression in either constant's value moves what the code
/// under test computes without moving the test — see `TranscriptViewRowLayoutTests`'s own doc
/// comment on why that distinction is the whole point.
final class RowHeightTableLayoutTests: XCTestCase {

    private func table(rows: Int) -> MarkdownTable {
        let cell = InlineText(runs: [InlineRun(text: "x")])
        return MarkdownTable(
            alignments: [nil], header: [cell], rows: Array(repeating: [cell], count: rows))
    }

    /// A gap before every text row (header included) and before the divider row between them —
    /// `rows.count + 1` gaps for a table with `rows.count` data rows, not `rows.count`: the
    /// divider is itself a row the grid puts a gap before, the boundary a loop is likeliest to
    /// get wrong.
    func testSpacingAppliesBeforeEveryRowIncludingTheDivider() {
        // 3 data rows + 1 header = 4 text rows, 4 gaps of 5, one divider of 2.
        let actual = MarkdownTableLayout.height(for: table(rows: 3), rowHeight: 20, rowSpacing: 5, dividerHeight: 2)
        XCTAssertEqual(actual, 4 * 20 + 4 * 5 + 2)
    }

    func testATableWithNoDataRowsStillCountsTheHeaderRowsGapAndTheDivider() {
        // 1 text row (header only), 1 gap, one divider.
        let actual = MarkdownTableLayout.height(for: table(rows: 0), rowHeight: 20, rowSpacing: 5, dividerHeight: 2)
        XCTAssertEqual(actual, 1 * 20 + 1 * 5 + 2)
    }

    /// Backward-compatible with a caller that only wants the text-row boundary math — the
    /// original two-argument tests in `TranscriptViewMarkdownTableLayoutTests` exercise exactly
    /// this default and must keep passing unchanged.
    func testSpacingAndDividerDefaultToZero() {
        XCTAssertEqual(
            MarkdownTableLayout.height(for: table(rows: 3), rowHeight: 20),
            MarkdownTableLayout.height(for: table(rows: 3), rowHeight: 20, rowSpacing: 0, dividerHeight: 0))
    }
}
