import XCTest

@testable import PAIKit

/// The spike red team `22c9ef7f` finding C1 asked for: a worst-case message — a GFM table plus
/// several highlighted code blocks — timed end to end, before more is built on top of the
/// precomputed-height design.
///
/// What this can and cannot answer, precisely: parsing runs the real swift-markdown parser, so
/// its timing here is the real number. Composition runs the real `MessageContentLayoutComposer`
/// and `BlockHeightCache` logic, so *their* overhead is real too. Only the per-block measurement
/// itself is a stand-in — `StubBlockMeasurer` does real, input-sensitive work rather than
/// returning a constant, so it stresses the composition loop honestly, but it is not TextKit and
/// says nothing about whether laying out a GFM table or a highlighted code block on a device is
/// itself fast. That half of finding C1 stays open until this runs on Apple hardware; see the
/// report for how to extend this file with a real measurer once one exists.
///
/// Thresholds here are regression guards, not performance targets: generous enough not to flake
/// on a loaded CI runner, tight enough to catch an accidental quadratic blowup in parsing or
/// composition. The actual numbers this run measured belong in the report that cites this file,
/// not hardcoded into an assertion that would silently loosen the moment someone's refactor made
/// it necessary.
final class WorstCaseLayoutTimingTests: XCTestCase {

    /// A synthetic worst case in the shape recon `976283e9` describes as the genuinely hard
    /// content: a wide GFM table, several syntax-highlighted-in-the-real-renderer code blocks,
    /// and prose stitching them together — comparable in size to a large tool result with
    /// commentary, on the larger end of what a real transcript message reaches.
    private func worstCaseMarkdownSource() -> String {
        var lines: [String] = []

        for section in 1...6 {
            lines.append("## Section \(section)")
            lines.append("")
            for paragraph in 1...3 {
                lines.append(
                    "This is paragraph \(paragraph) of section \(section), with enough ordinary "
                        + "prose in it to resemble a real assistant reply rather than a synthetic "
                        + "filler line, including `inline code`, **bold text**, and a [link](https://example.com/\(section)/\(paragraph))."
                )
                lines.append("")
            }

            lines.append("```swift")
            for codeLine in 1...150 {
                lines.append(
                    "let value\(codeLine) = computeSomething(section: \(section), index: \(codeLine)) // a realistic line of code"
                )
            }
            lines.append("```")
            lines.append("")
        }

        lines.append("| " + (1...12).map { "Column \($0)" }.joined(separator: " | ") + " |")
        lines.append("| " + (1...12).map { _ in "---" }.joined(separator: " | ") + " |")
        for row in 1...60 {
            lines.append("| " + (1...12).map { "r\(row)c\($0)" }.joined(separator: " | ") + " |")
        }

        return lines.joined(separator: "\n")
    }

    func testParsingAWorstCaseMessageCompletesWellWithinBudget() {
        let source = worstCaseMarkdownSource()
        XCTAssertGreaterThan(
            source.utf8.count, 20_000,
            "the synthetic source is smaller than intended, so this proves less than it claims to")

        let clock = ContinuousClock()
        let start = clock.now
        let blocks = MarkdownParser.parse(source)
        let elapsed = clock.now - start

        XCTAssertFalse(blocks.isEmpty)
        XCTAssertTrue(
            blocks.contains { if case .table = $0 { return true } else { return false } },
            "the table did not survive parsing, so this run measured the wrong content")
        let codeBlockCount = blocks.filter { if case .codeBlock = $0 { return true } else { return false } }.count
        XCTAssertEqual(codeBlockCount, 6)

        // A regression guard, not a target: swift-markdown parsing ~50KB of realistic markdown on
        // a Linux CI runner should be a small fraction of a second. Ten seconds is loose enough to
        // absorb CI contention while still catching an accidental quadratic pass over the source.
        XCTAssertLessThan(
            elapsed, .seconds(10),
            "parsing took \(elapsed) for \(source.utf8.count) bytes — investigate before assuming this scales")
    }

    /// Composition and caching cost, isolated from parsing: this is the part
    /// `MessageContentLayoutComposer` and `BlockHeightCache` are actually responsible for, and
    /// the part this package can prove something real about without a device.
    func testComposingAWorstCaseMessageIsNegligibleNextToParsing() {
        let source = worstCaseMarkdownSource()
        let blocks = MarkdownParser.parse(source)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()
        let environment = MeasurementEnvironment(sizeCategoryToken: "L")
        let metrics = MessageLayoutMetrics(blockSpacing: 8)

        let clock = ContinuousClock()
        let start = clock.now
        let layout = MessageContentLayoutComposer.layout(
            of: blocks, width: 350, environment: environment, metrics: metrics, measurer: measurer, cache: cache
        )
        let firstPassElapsed = clock.now - start

        XCTAssertEqual(layout.blocks.count, blocks.count)
        XCTAssertGreaterThan(layout.totalHeight, 0)
        XCTAssertLessThan(
            firstPassElapsed, .seconds(2),
            "composing \(blocks.count) blocks for the first time took \(firstPassElapsed)")

        // The scroll-time case: the same message laid out again, as happens whenever a cell
        // scrolls back on screen. Every block should hit the cache, so this pass measures nothing
        // and must be far faster than the first — the property the whole design exists for.
        let rescoreStart = clock.now
        _ = MessageContentLayoutComposer.layout(
            of: blocks, width: 350, environment: environment, metrics: metrics, measurer: measurer, cache: cache
        )
        let secondPassElapsed = clock.now - rescoreStart

        XCTAssertEqual(
            measurer.callCount, blocks.count,
            "the second pass re-measured at least one block instead of hitting the cache for every one of them")
        XCTAssertLessThan(
            secondPassElapsed, firstPassElapsed, "a fully-cached re-layout was not faster than the first, uncached one")
    }
}
