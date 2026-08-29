import XCTest

@testable import PAIKit

final class TranscriptViewMarkdownTableLayoutTests: XCTestCase {

    private func table(rows: Int) -> MarkdownTable {
        let cell = InlineText(runs: [InlineRun(text: "x")])
        return MarkdownTable(
            alignments: [nil], header: [cell], rows: Array(repeating: [cell], count: rows))
    }

    /// One header row plus every data row — the `+1` is exactly the boundary a loop is most
    /// likely to get wrong (off by a row, or dropping the header entirely).
    func testHeightIncludesTheHeaderRowOnTopOfEveryDataRow() {
        XCTAssertEqual(MarkdownTableLayout.height(for: table(rows: 3), rowHeight: 20), 80)
    }

    func testATableWithNoDataRowsIsStillJustTheHeaderRow() {
        XCTAssertEqual(MarkdownTableLayout.height(for: table(rows: 0), rowHeight: 20), 20)
    }

    /// Column count must never enter the formula — a table cell never wraps (a wide table scrolls
    /// horizontally instead of reflowing; see the type's doc comment), so nothing about a row's
    /// height can depend on how many columns are in it. A change that started factoring in
    /// `table.columnCount` would grow this number for no visible reason.
    func testHeightIgnoresColumnCount() {
        let cell = InlineText(runs: [InlineRun(text: "x")])
        let wide = MarkdownTable(
            alignments: Array(repeating: nil, count: 12), header: Array(repeating: cell, count: 12),
            rows: [Array(repeating: cell, count: 12)])
        XCTAssertEqual(
            MarkdownTableLayout.height(for: wide, rowHeight: 20),
            MarkdownTableLayout.height(for: table(rows: 1), rowHeight: 20))
    }
}
