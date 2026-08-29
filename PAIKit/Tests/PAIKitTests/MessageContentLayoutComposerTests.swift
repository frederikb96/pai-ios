import XCTest

@testable import PAIKit

/// The composer does two things worth testing separately from `BlockHeightCache` itself: it gets
/// the offset/spacing arithmetic right, and it actually routes every block through the cache it
/// was handed rather than measuring directly. Neither is visible from a single block's height, so
/// neither would be caught by `BlockHeightCacheTests` alone.
final class MessageContentLayoutComposerTests: XCTestCase {

    private let environment = MeasurementEnvironment(sizeCategoryToken: "L")
    private let metrics = MessageLayoutMetrics(blockSpacing: 8)

    private func paragraph(_ text: String) -> MarkdownBlock {
        .paragraph(InlineText(runs: [InlineRun(text: text)]))
    }

    // MARK: - Offset and total-height arithmetic

    /// Expected values are derived independently from the stub's own formula and the spacing
    /// constant, not by calling the composer a second time — an off-by-one in the loop (spacing
    /// applied before the first block, or omitted after the last, or double-counted) changes
    /// these numbers without changing whether "a height came back".
    func testOffsetsAccumulateHeightPlusSpacingBetweenBlocks() {
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()
        let blocks = [paragraph("a"), paragraph("bb"), paragraph("ccc")]

        let layout = MessageContentLayoutComposer.layout(
            of: blocks, width: 300, environment: environment, metrics: metrics, measurer: measurer, cache: cache
        )

        let expectedHeights = blocks.map { measurer.height(of: $0, width: 300, environment: environment) }

        XCTAssertEqual(layout.blocks.count, 3)
        XCTAssertEqual(layout.blocks[0].offset, 0)
        XCTAssertEqual(layout.blocks[1].offset, expectedHeights[0] + metrics.blockSpacing)
        XCTAssertEqual(layout.blocks[2].offset, expectedHeights[0] + expectedHeights[1] + 2 * metrics.blockSpacing)

        let expectedTotal = expectedHeights.reduce(0, +) + metrics.blockSpacing * Double(blocks.count - 1)
        XCTAssertEqual(layout.totalHeight, expectedTotal)
    }

    /// The single-block case is the one most likely to be right by accident in a buggy loop (no
    /// spacing has anywhere to go wrong), so it is worth its own assertion that no spacing leaks
    /// in before or after the only block.
    func testASingleBlockCarriesNoSpacing() {
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()
        let block = paragraph("only one")

        let layout = MessageContentLayoutComposer.layout(
            of: [block], width: 300, environment: environment, metrics: metrics, measurer: measurer, cache: cache
        )

        XCTAssertEqual(layout.blocks[0].offset, 0)
        XCTAssertEqual(layout.totalHeight, measurer.height(of: block, width: 300, environment: environment))
    }

    func testAnEmptyBlockListProducesZeroHeightAndNoRows() {
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let layout = MessageContentLayoutComposer.layout(
            of: [], width: 300, environment: environment, metrics: metrics, measurer: measurer, cache: cache
        )

        XCTAssertTrue(layout.blocks.isEmpty)
        XCTAssertEqual(layout.totalHeight, 0)
    }

    // MARK: - The composer shares the cache it is handed, across messages

    /// This is the actual payoff of keying the cache by block content rather than by message:
    /// composing two different "messages" that happen to share one block measures that block
    /// once. Heights alone cannot distinguish "shared cache" from "each composition measuring its
    /// own blocks fresh" — both produce the same numbers — so this asserts on the measurer's call
    /// count, the one thing a composer that built its own private cache internally would break
    /// silently while every height-based test kept passing.
    func testTwoMessagesSharingABlockMeasureItOnlyOnce() {
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()
        let shared = paragraph("shared across two messages")
        let firstMessage = [paragraph("first message opener"), shared]
        let secondMessage = [shared, paragraph("second message closer")]

        _ = MessageContentLayoutComposer.layout(
            of: firstMessage, width: 300, environment: environment, metrics: metrics, measurer: measurer, cache: cache
        )
        let countAfterFirst = measurer.callCount

        _ = MessageContentLayoutComposer.layout(
            of: secondMessage, width: 300, environment: environment, metrics: metrics, measurer: measurer, cache: cache
        )

        // The second composition contributes one new call, for its own unique block — not two.
        XCTAssertEqual(
            measurer.callCount, countAfterFirst + 1,
            "the shared block was re-measured instead of hitting the cache the second composition was handed")
    }

    // MARK: - Expansion is the caller's array, not a parameter here

    /// There is no expansion flag on the composer — this test is the reason: passing a shorter
    /// array (the "collapsed" case) must produce a shorter, cheaper layout on its own, with
    /// nothing extra to wire up. If a future change added expansion-aware branching inside the
    /// composer, this is the test that would start needing it.
    func testFewerBlocksProduceAProportionatelySmallerLayout() {
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()
        let allBlocks = [paragraph("one"), paragraph("two"), paragraph("three")]
        let collapsed = Array(allBlocks.prefix(1))

        let expanded = MessageContentLayoutComposer.layout(
            of: allBlocks, width: 300, environment: environment, metrics: metrics, measurer: measurer, cache: cache
        )
        let collapsedLayout = MessageContentLayoutComposer.layout(
            of: collapsed, width: 300, environment: environment, metrics: metrics, measurer: measurer, cache: cache
        )

        XCTAssertLessThan(collapsedLayout.totalHeight, expanded.totalHeight)
        XCTAssertEqual(collapsedLayout.totalHeight, collapsedLayout.blocks[0].height)
    }
}
