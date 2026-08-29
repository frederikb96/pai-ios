import XCTest

@testable import PAIKit

final class TranscriptViewRowLayoutTests: XCTestCase {

    private let environment = MeasurementEnvironment(sizeCategoryToken: "")
    private let metrics = MessageLayoutMetrics(blockSpacing: 4)
    private let width: Double = 400

    private func message(
        type: MessageType,
        subtype: String? = nil,
        content: String? = nil,
        thinking: String? = nil,
        toolCalls: [ToolCall]? = nil,
        toolResult: ToolResult? = nil,
        timestamp: String? = "2026-08-29T00:00:00Z"
    ) -> Message {
        Message(
            id: 1, sessionId: "s", type: type, subtype: subtype, outboxId: nil, timestamp: timestamp,
            content: content, thinking: thinking, toolCalls: toolCalls, toolResult: toolResult,
            hookSummary: nil, tokens: nil, origin: nil, originMeta: nil, createdAt: nil)
    }

    private func expandAll(_: String) -> Bool { true }
    private func expandNone(_: String) -> Bool { false }

    /// The independent yardstick every expected value below is built from — the same composer
    /// `TranscriptRowLayout` itself calls, invoked directly rather than through the code under
    /// test, exactly as `MessageContentLayoutComposerTests` already does for its own expectations.
    private func measuredContentHeight(_ blocks: [MarkdownBlock], measurer: StubBlockMeasurer, cache: BlockHeightCache)
        -> Double
    {
        MessageContentLayoutComposer.layout(
            of: blocks, width: width, environment: environment, metrics: metrics, measurer: measurer, cache: cache
        )
        .totalHeight
    }

    func testHeightIsNilForARouteThatRendersNothing() {
        let msg = message(type: .user, content: "<local-command-caveat>ignore</local-command-caveat>")
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()
        XCTAssertNil(
            TranscriptRowLayout.height(
                for: msg, width: width, environment: environment, isExpanded: expandAll, measurer: measurer,
                cache: cache,
                metrics: metrics))
    }

    func testAssistantBubbleAddsItsOwnPaddingAndTheRowTimestamp() {
        let msg = message(type: .assistant, content: "A short reply.")
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isExpanded: expandAll, measurer: measurer, cache: cache,
            metrics: metrics)

        let content = measuredContentHeight(MarkdownParser.parse("A short reply."), measurer: measurer, cache: cache)
        let expected = content + TranscriptRowMetrics.bubbleVerticalPadding + TranscriptRowMetrics.timestampHeight
        XCTAssertEqual(actual, expected)
    }

    /// A collapsed card hands the composer zero blocks, so its content height is zero — but the
    /// header chrome must still be reserved, and the content padding must NOT be, since there is
    /// no content edge to pad around. Both halves of that branch are worth their own assertion.
    func testACollapsedToolCallReservesOnlyTheHeaderHeight() {
        let calls = [ToolCall(id: "1", name: "Bash", input: ["command": .string("ls")])]
        let msg = message(type: .assistant, toolCalls: calls, timestamp: nil)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isExpanded: expandNone, measurer: measurer, cache: cache,
            metrics: metrics)

        XCTAssertEqual(actual, TranscriptRowMetrics.cardHeaderHeight)
    }

    func testAnExpandedToolCallAddsHeaderContentAndContentPadding() {
        let calls = [ToolCall(id: "1", name: "Bash", input: ["command": .string("ls")])]
        let msg = message(type: .assistant, toolCalls: calls, timestamp: nil)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isExpanded: expandAll, measurer: measurer, cache: cache,
            metrics: metrics)

        let text = MessageDisplay.displayText(of: MessageDisplay.spec(for: calls[0]))
        let content = measuredContentHeight([.codeBlock(language: nil, code: text)], measurer: measurer, cache: cache)
        let expected = TranscriptRowMetrics.cardHeaderHeight + content + TranscriptRowMetrics.cardContentVerticalPadding
        XCTAssertEqual(actual, expected)
    }

    /// Two cards in one assistant turn must be separated by the inter-card spacing exactly once —
    /// not once per card, not omitted entirely. The classic off-by-one a hand-written loop invites.
    func testTwoCardsInOneTurnAreSeparatedByInterCardSpacingExactlyOnce() {
        let msg = message(type: .assistant, content: "Reply.", thinking: "Thinking about it.", timestamp: nil)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isExpanded: expandAll, measurer: measurer, cache: cache,
            metrics: metrics)

        let thinkingContent = measuredContentHeight(
            [.codeBlock(language: nil, code: "Thinking about it.")], measurer: measurer, cache: cache)
        let thinkingHeight =
            TranscriptRowMetrics.cardHeaderHeight + thinkingContent + TranscriptRowMetrics.cardContentVerticalPadding
        let bubbleContent = measuredContentHeight(MarkdownParser.parse("Reply."), measurer: measurer, cache: cache)
        let bubbleHeight = bubbleContent + TranscriptRowMetrics.bubbleVerticalPadding
        let expected = thinkingHeight + TranscriptRowMetrics.interCardSpacing + bubbleHeight

        XCTAssertEqual(actual, expected)
    }

    func testNoTimestampLineIsAddedWhenTheMessageHasNone() {
        let msg = message(type: .assistant, content: "Reply.", timestamp: nil)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isExpanded: expandAll, measurer: measurer, cache: cache,
            metrics: metrics)

        let content = measuredContentHeight(MarkdownParser.parse("Reply."), measurer: measurer, cache: cache)
        XCTAssertEqual(actual, content + TranscriptRowMetrics.bubbleVerticalPadding)
    }

    /// An argument-free command degrades to a compact line with no header chrome or padding at
    /// all — the "action with nothing to show" case the web renders as bare text.
    func testACommandWithNoArgumentsIsExactlyTheHeaderHeight() {
        let msg = message(type: .user, subtype: "command", content: "/context\n\n", timestamp: nil)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isExpanded: expandAll, measurer: measurer, cache: cache,
            metrics: metrics)

        XCTAssertEqual(actual, TranscriptRowMetrics.cardHeaderHeight)
    }
}
