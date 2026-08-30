import XCTest

@testable import PAIKit

/// `TranscriptRowLayout.blockOffset` is what lands a search hit inside a specific block rather
/// than merely scrolling to a row that can be thousands of points tall — see that function's own
/// doc comment. Every expectation here is built from the same independent yardstick
/// `TranscriptViewRowLayoutTests` uses: literal widths and constants, never the ones the code
/// under test itself computes from, so a chrome-constant mutation moves what is measured without
/// moving what the test expects.
final class SearchBlockOffsetTests: XCTestCase {

    private let environment = MeasurementEnvironment(sizeCategoryToken: "")
    private let metrics = MessageLayoutMetrics(blockSpacing: 4)
    private let width: Double = 400

    private func text(linesAtWidth width: Double, count: Int = 100) -> String {
        String(repeating: "x", count: Int(width) * count)
    }

    private func message(
        type: MessageType,
        subtype: String? = nil,
        content: String? = nil,
        thinking: String? = nil,
        toolCalls: [ToolCall]? = nil
    ) -> Message {
        Message(
            id: 1, sessionId: "s", type: type, subtype: subtype, outboxId: nil, timestamp: nil, content: content,
            thinking: thinking, toolCalls: toolCalls, toolResult: nil, hookSummary: nil, tokens: nil, origin: nil,
            originMeta: nil, createdAt: nil)
    }

    private func expandAll(_: String) -> Bool { true }

    /// The single-block case: an assistant bubble's block offset is always its card's own chrome,
    /// since a bubble never holds more than one paragraph block. `bubbleVerticalPadding / 2` is
    /// the top half of the padding `AssistantBubbleView` applies around its content.
    func testBlockOffsetInsideASingleBlockCardIsExactlyItsChrome() {
        let msg = message(type: .assistant, content: "Reply.")
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let offset = TranscriptRowLayout.blockOffset(
            cardIndex: 0, blockIndex: 0, for: msg, width: width, environment: environment, isExpanded: expandAll,
            measurer: measurer, cache: cache, metrics: metrics)

        XCTAssertEqual(offset, 5)  // TranscriptRowMetrics.bubbleVerticalPadding (10) / 2
    }

    /// A collapsible card's block sits below its header, half the content padding further down —
    /// the counterpart to `testAnExpandedToolCallAddsHeaderContentAndContentPadding` in
    /// `TranscriptViewRowLayoutTests`.
    func testBlockOffsetInsideACollapsibleCardIsBelowItsHeader() {
        let calls = [ToolCall(id: "1", name: "Bash", input: ["command": .string("ls")])]
        let msg = message(type: .assistant, toolCalls: calls)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let offset = TranscriptRowLayout.blockOffset(
            cardIndex: 0, blockIndex: 0, for: msg, width: width, environment: environment, isExpanded: expandAll,
            measurer: measurer, cache: cache, metrics: metrics)

        XCTAssertEqual(offset, 38)  // 32 header + 12 / 2 content padding
    }

    /// The second card in a turn must be pushed down by the first card's own full height plus one
    /// inter-card spacing — proving the preceding-cards loop, not just one card's own chrome.
    func testBlockOffsetInASecondCardAccountsForTheFirstCardsWholeHeight() {
        let cardSensitiveText = text(linesAtWidth: 400 - 20)
        let msg = message(type: .assistant, content: "Reply.", thinking: cardSensitiveText)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        // Card 0 is the thinking block, card 1 is the assistant bubble reply — see
        // `TranscriptRowPlan`'s ordering (thinking, then tool calls, then the reply).
        let offset = TranscriptRowLayout.blockOffset(
            cardIndex: 1, blockIndex: 0, for: msg, width: width, environment: environment, isExpanded: expandAll,
            measurer: measurer, cache: cache, metrics: metrics)

        let thinkingContent = MessageContentLayoutComposer.layout(
            of: [.codeBlock(language: nil, code: cardSensitiveText)], width: 400 - 20, environment: environment,
            metrics: metrics, measurer: measurer, cache: cache
        ).totalHeight
        let thinkingHeight = 32 + thinkingContent + 12
        let expected = thinkingHeight + 8 + 5  // + inter-card spacing + the bubble's own top chrome
        XCTAssertEqual(offset, expected)
    }

    /// An agent message's body is real, possibly multi-block markdown — the one card kind where a
    /// second block's offset is not simply its card's chrome, but genuinely depends on the first
    /// block's own measured height.
    func testBlockOffsetOfASecondBlockWithinOneCardIncludesTheFirstBlocksHeight() {
        let msg = message(type: .user, subtype: "agent_message", content: "sender\n\nFirst line.\n\nSecond line.")
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let offsetOfFirst = TranscriptRowLayout.blockOffset(
            cardIndex: 0, blockIndex: 0, for: msg, width: width, environment: environment, isExpanded: expandAll,
            measurer: measurer, cache: cache, metrics: metrics)
        let offsetOfSecond = TranscriptRowLayout.blockOffset(
            cardIndex: 0, blockIndex: 1, for: msg, width: width, environment: environment, isExpanded: expandAll,
            measurer: measurer, cache: cache, metrics: metrics)

        XCTAssertEqual(offsetOfFirst, 38)  // 32 header + 12 / 2, same chrome as any other collapsible card
        XCTAssertGreaterThan(offsetOfSecond ?? 0, offsetOfFirst ?? 0)
    }

    func testBlockOffsetIsNilForACardIndexThatDoesNotExist() {
        let msg = message(type: .assistant, content: "Reply.")
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let offset = TranscriptRowLayout.blockOffset(
            cardIndex: 3, blockIndex: 0, for: msg, width: width, environment: environment, isExpanded: expandAll,
            measurer: measurer, cache: cache, metrics: metrics)

        XCTAssertNil(offset)
    }

    /// A block index past what a card currently has — the card has not actually been expanded yet
    /// under the `isExpanded` this call was given — degrades to the top of the card's own content
    /// rather than failing, since a caller is expected to expand first and this is the fallback
    /// for when it has not happened yet.
    func testBlockOffsetDegradesToTheCardsOwnContentTopWhenTheBlockIsNotThereYet() {
        let calls = [ToolCall(id: "1", name: "Bash", input: ["command": .string("ls")])]
        let msg = message(type: .assistant, toolCalls: calls)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let offset = TranscriptRowLayout.blockOffset(
            cardIndex: 0, blockIndex: 0, for: msg, width: width, environment: environment,
            isExpanded: { _ in false }, measurer: measurer, cache: cache, metrics: metrics)

        XCTAssertEqual(offset, 38)
    }
}
