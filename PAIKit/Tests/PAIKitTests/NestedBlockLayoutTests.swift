import XCTest

@testable import PAIKit

/// `NestedBlockLayout` exists so the geometry `TextKitBlockMeasurer` needs for a nested `.list`
/// or `.blockQuote` is provable without TextKit — these tests are that proof. Every expected
/// value below is built from **literal** numbers, never `TranscriptRowMetrics`'s own constants:
/// the code under test reads those constants itself, so an expectation built from the same
/// symbols would still pass after a mutation of one of them — the exact failure mode
/// `TranscriptViewRowLayoutTests`' own doc comment describes and this file inherits verbatim.
/// The literals here are `TranscriptRowMetrics`' current values (`listMarkerReservedWidth: 24`,
/// `listMarkerSpacing: 6`, `listItemSpacing: 4`, `blockQuoteRuleWidth: 3`, `blockQuoteSpacing: 8`)
/// at the time of writing, not re-derived from the type.
final class NestedBlockLayoutTests: XCTestCase {

    private let environment = MeasurementEnvironment(sizeCategoryToken: "")

    private func paragraph(_ text: String) -> MarkdownBlock {
        .paragraph(InlineText(runs: [InlineRun(text: text)]))
    }

    private func item(_ blocks: [MarkdownBlock]) -> MarkdownListItem {
        MarkdownListItem(blocks: blocks)
    }

    private func bulletList(_ items: [MarkdownListItem]) -> MarkdownList {
        MarkdownList(marker: .bullet, items: items)
    }

    /// A string whose length is an *exact* multiple of `width` — a `ceil` boundary, so any width
    /// even a few points off from the one intended lands in a different line-count bucket. Same
    /// reasoning and the same caution against a merely "long" fixture as
    /// `TranscriptViewRowLayoutTests`' own `text(linesAtWidth:)` doc comment spells out.
    private func text(linesAtWidth width: Double, count: Int) -> String {
        String(repeating: "x", count: Int(width) * count)
    }

    /// Delegates `.list`/`.blockQuote` back through `NestedBlockLayout` with itself as the
    /// measurer — the same shape `TextKitBlockMeasurer` uses for real (passing `self`), kept
    /// testable here because this wrapper, unlike TextKit, needs no Apple framework. Everything
    /// else is `StubBlockMeasurer`'s own width-sensitive formula.
    private struct RecursingBlockMeasurer: BlockMeasuring {
        let leaf: StubBlockMeasurer

        func height(of block: MarkdownBlock, width: Double, environment: MeasurementEnvironment) -> Double {
            switch block {
            case .list(let list):
                return NestedBlockLayout.listHeight(list, width: width, environment: environment, measurer: self)
            case .blockQuote(let blocks):
                return NestedBlockLayout.blockQuoteHeight(
                    blocks, width: width, environment: environment, measurer: self)
            default:
                return leaf.height(of: block, width: width, environment: environment)
            }
        }
    }

    // MARK: - The core bug: an item wraps at the true width but not at the outer one

    /// 371 characters at the list's own 400pt width fits on one line (`ceil(371/400) == 1`); at
    /// the correctly narrowed item width of 370 (`400 − 24 − 6`) it wraps to two
    /// (`ceil(371/370) == 2`). Measuring the item at the unnarrowed outer width — what flattening
    /// the whole list into one string at 400 did — silently drops the second line's 20pt.
    func testAnItemWrapsAtTheNarrowedWidthButNotAtTheOuterWidth() {
        let list = bulletList([item([paragraph(String(repeating: "x", count: 371))])])
        let measurer = RecursingBlockMeasurer(leaf: StubBlockMeasurer())

        let actual = NestedBlockLayout.listHeight(list, width: 400, environment: environment, measurer: measurer)

        XCTAssertEqual(actual, 40, "expected two 20pt lines at the narrowed 370pt item width")
    }

    // MARK: - Nesting narrows by another inset at every level

    /// A list nested inside one item of an outer list must be measured at `400 − 30 − 30 = 340`,
    /// not at `400` (no narrowing) or `370` (only the outer level's own narrowing) — three widths
    /// a 340-char-multiple fixture divides differently, so a fix that narrows only one level still
    /// fails this.
    func testATwoLevelNestedListNarrowsByBothLevelsOwnInset() {
        let innerText = text(linesAtWidth: 340, count: 50)
        let inner = bulletList([item([paragraph(innerText)])])
        let outer = bulletList([item([.list(inner)])])
        let measurer = RecursingBlockMeasurer(leaf: StubBlockMeasurer())

        let actual = NestedBlockLayout.listHeight(outer, width: 400, environment: environment, measurer: measurer)

        XCTAssertEqual(actual, 50 * 20, "expected the inner list's own text measured at 340, not 370 or 400")
    }

    /// The same property one level deeper: `400 − 30 − 30 − 30 = 310`. A fix that narrows the
    /// first two levels but re-flattens (or forgets to recurse) at the third would land on 340 or
    /// 370's own line count instead of 310's.
    func testAThreeLevelNestedListNarrowsByEveryLevelsOwnInset() {
        let innermostText = text(linesAtWidth: 310, count: 40)
        let innermost = bulletList([item([paragraph(innermostText)])])
        let middle = bulletList([item([.list(innermost)])])
        let outer = bulletList([item([.list(middle)])])
        let measurer = RecursingBlockMeasurer(leaf: StubBlockMeasurer())

        let actual = NestedBlockLayout.listHeight(outer, width: 400, environment: environment, measurer: measurer)

        XCTAssertEqual(actual, 40 * 20, "expected the innermost list's own text measured at 310")
    }

    // MARK: - Item gaps apply at every level, not only the outermost

    /// Two items at the outer level and two at each inner level: the 4pt item gap must appear
    /// once between the outer pair and once between each inner pair — three separate places a
    /// dropped gap could hide, all summed into one number here.
    func testItemGapsAreSummedAtEveryNestingLevel() {
        let short = paragraph("x")  // one line regardless of width: 20pt, at any positive width.
        let inner = bulletList([item([short]), item([short])])
        let outer = bulletList([item([.list(inner)]), item([.list(inner)])])
        let measurer = RecursingBlockMeasurer(leaf: StubBlockMeasurer())

        let actual = NestedBlockLayout.listHeight(outer, width: 400, environment: environment, measurer: measurer)

        // Each inner list: two 20pt items + one 4pt gap between them = 44.
        // Outer list: two 44pt items + one 4pt gap between them = 92.
        XCTAssertEqual(actual, 92)
    }

    // MARK: - A block quote recurses and narrows exactly like a list

    /// A block quote nested inside another must narrow by `3 + 8 = 11` at each level: `400 − 11 −
    /// 11 = 378` for the innermost text — distinct from `389` (one level) and `400` (none) at a
    /// 378-char-multiple fixture.
    func testATwoLevelNestedBlockQuoteNarrowsByBothLevelsOwnInset() {
        let innerText = text(linesAtWidth: 378, count: 45)
        let inner: [MarkdownBlock] = [paragraph(innerText)]
        let outer: [MarkdownBlock] = [.blockQuote(inner)]
        let measurer = RecursingBlockMeasurer(leaf: StubBlockMeasurer())

        let actual = NestedBlockLayout.blockQuoteHeight(outer, width: 400, environment: environment, measurer: measurer)

        XCTAssertEqual(actual, 45 * 20, "expected the inner quote's own text measured at 378, not 389 or 400")
    }

    // MARK: - Sibling blocks inside one item are summed with the shared block spacing

    /// Two blocks inside the same list item — a short paragraph followed by a nested list — must
    /// be separated by the same 8pt `markdownBlockSpacing` gap `MarkdownContentView`'s own
    /// `VStack` puts between any two blocks, on top of each block's own height.
    func testSiblingBlocksWithinOneItemAreSeparatedByTheSharedBlockSpacing() {
        let nested = bulletList([item([paragraph("x")])])
        let list = bulletList([item([paragraph("x"), .list(nested)])])
        let measurer = RecursingBlockMeasurer(leaf: StubBlockMeasurer())

        let actual = NestedBlockLayout.listHeight(list, width: 400, environment: environment, measurer: measurer)

        // Paragraph "x": 20. Gap: 8. Nested list (one 20pt item, no inner gap): 20.
        XCTAssertEqual(actual, 20 + 8 + 20)
    }
}
