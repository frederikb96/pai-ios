import XCTest

@testable import PAIKit

final class TranscriptViewRowLayoutTests: XCTestCase {

    private let environment = MeasurementEnvironment(sizeCategoryToken: "")
    private let metrics = MessageLayoutMetrics(blockSpacing: 4)
    private let width: Double = 400

    /// `StubBlockMeasurer` reports `ceil(charCount / width)` lines — so a string whose length is
    /// an *exact* multiple of the correctly-narrowed width lands precisely on a line-count
    /// boundary, and any width even a few points off (too little inset applied, too much, or
    /// none at all) lands in a different `ceil` bucket. A short string, or one merely "long" (the
    /// original fixtures here used `"Reply."`, then a first attempt at this file used 1000
    /// characters), always measures to the same line count regardless of width whenever the
    /// candidate widths happen to divide it the same way — which is exactly what let the first
    /// attempt's assertions pass even with `bubbleHorizontalPadding` mutated to `0`, caught only
    /// by then actually running that mutation rather than trusting the string was "long enough".
    /// 100 exact multiples gives roughly a 4pt boundary spacing, comfortably finer than any
    /// chrome inset this file asserts on.
    private func text(linesAtWidth width: Double, count: Int = 100) -> String {
        String(repeating: "x", count: Int(width) * count)
    }

    /// Sized against 324 = 400 − 48 (the leading gutter) − 2×14, the content width a right-aligned
    /// bubble (a command's own arguments, a relayed prompt) asserts on — never Freddy's own
    /// prompt, which this file has no test for since `UserBubbleView` shares the identical
    /// `.userBubble` formula.
    private lazy var bubbleSensitiveText = text(linesAtWidth: 400 - 48 - 28)
    /// Sized against 380 = 400 − 2×10, the content width both a collapsible card and the
    /// uncontained assistant reply assert on — the two share one formula since neither has a
    /// bubble's own horizontal padding or leading gutter any more.
    private lazy var cardSensitiveText = text(linesAtWidth: 400 - 20)

    private func message(
        type: MessageType,
        subtype: String? = nil,
        content: String? = nil,
        thinking: String? = nil,
        toolCalls: [ToolCall]? = nil,
        toolResult: ToolResult? = nil,
        originMeta: [String: String]? = nil,
        timestamp: String? = "2026-08-29T00:00:00Z"
    ) -> Message {
        Message(
            id: 1, sessionId: "s", type: type, subtype: subtype, outboxId: nil, timestamp: timestamp,
            content: content, thinking: thinking, toolCalls: toolCalls, toolResult: toolResult,
            hookSummary: nil, tokens: nil, origin: nil, originMeta: originMeta, createdAt: nil)
    }

    private func expandAll(_: String) -> Bool { true }
    private func expandNone(_: String) -> Bool { false }

    /// The independent yardstick every expected value below is built from — the same composer
    /// `TranscriptRowLayout` itself calls, invoked directly rather than through the code under
    /// test. `atWidth` is always a **literal** number here, never one of `TranscriptRowMetrics`'s
    /// own constants: the code under test computes its own content width from those constants, so
    /// building the expectation from the same symbols would make the test equal itself no matter
    /// what the constant's value is — the exact failure mode this file's own report proved by
    /// mutation (`cardHeaderHeight` 32 → 99, zero new failures). A literal width the test derives
    /// independently is what turns that same mutation red.
    private func measuredContentHeight(
        _ blocks: [MarkdownBlock], atWidth width: Double, measurer: StubBlockMeasurer, cache: BlockHeightCache
    ) -> Double {
        MessageContentLayoutComposer.layout(
            of: blocks, width: width, environment: environment, metrics: metrics, measurer: measurer, cache: cache
        ).totalHeight
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

    /// The reply is uncontained — no bubble padding of its own, just the same 20 = 2×10 inset
    /// every collapsible card uses (literal here, not `TranscriptRowMetrics.cardHorizontalPadding`,
    /// so a mutation of that constant moves what the code measures at without moving this
    /// expectation) — plus the row's own trailing timestamp chrome.
    func testAssistantBubbleAddsNoChromeOfItsOwnButStillGetsTheRowTimestamp() {
        let msg = message(type: .assistant, content: cardSensitiveText)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isExpanded: expandAll, measurer: measurer, cache: cache,
            metrics: metrics)

        let content = measuredContentHeight(
            MarkdownParser.parse(cardSensitiveText), atWidth: 400 - 20, measurer: measurer, cache: cache)
        // 8: the inter-card spacing `TranscriptRowContent`'s `VStack` puts before every child, the
        // timestamp line included. 16: the timestamp line.
        let expected = content + 8 + 16
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

        XCTAssertEqual(actual, 32)
    }

    /// The companion to the collapsed case above: an *expanded* card whose body happens to be
    /// empty (a system row with nothing to report) still has `CardChrome` padding its content —
    /// the padding wraps whatever `content()` it was handed whenever `isExpanded` is true, even
    /// when that content draws nothing. `card.blocks.isEmpty` is true in both the collapsed and
    /// this expanded-but-empty case, so a formula that branched on it instead of on whether the
    /// card is actually expanded would return 32 here too, not 44.
    func testAnExpandedSystemCardWithAnEmptyBodyStillReservesTheContentPadding() {
        let msg = message(type: .system, timestamp: nil)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isExpanded: expandAll, measurer: measurer, cache: cache,
            metrics: metrics)

        XCTAssertEqual(actual, 32 + 12)
    }

    // MARK: - User bubble attachments

    /// `UserBubbleView`'s `VStack` puts a gap between every pair of its children — here, two
    /// attachment chips and nothing else, since the text is empty and draws no bubble at all. The
    /// old formula added the text bubble's own padding unconditionally and no inter-chip gap;
    /// this is exact only if both halves of that mistake are fixed together.
    func testAttachmentsWithNoTextAddOnlyChipHeightsAndTheGapsBetweenThem() {
        let msg = message(
            type: .user, content: ".claude/attachments/a/one.png .claude/attachments/a/two.png", timestamp: nil)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isExpanded: expandAll, measurer: measurer, cache: cache,
            metrics: metrics)

        // Two 22pt chips, one 6pt gap between them — no text bubble, so no bubble padding either.
        XCTAssertEqual(actual, 2 * 22 + 6)
    }

    /// With both text and attachments present, the gap applies between the text bubble and the
    /// first chip too, not only between chips — three children, two gaps.
    func testTextAndAttachmentsTogetherGapBetweenTheBubbleAndEveryChipToo() {
        let msg = message(
            type: .user,
            content: "\(bubbleSensitiveText)\n\n.claude/attachments/a/one.png .claude/attachments/a/two.png",
            timestamp: nil)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isExpanded: expandAll, measurer: measurer, cache: cache,
            metrics: metrics)

        let content = measuredContentHeight(
            [.paragraph(InlineText(runs: [InlineRun(text: bubbleSensitiveText)]))], atWidth: 400 - 48 - 28,
            measurer: measurer, cache: cache)
        // 10: the text bubble's own vertical padding. 44: two 22pt chips. 12: two 6pt gaps (bubble
        // → first chip, first chip → second).
        let expected = content + 10 + 44 + 12
        XCTAssertEqual(actual, expected)
    }

    /// 20 is `CardChrome`'s own horizontal padding (`.padding(.horizontal, 10)`) doubled.
    func testAnExpandedToolCallAddsHeaderContentAndContentPadding() {
        let calls = [ToolCall(id: "1", name: "Bash", input: ["command": .string(cardSensitiveText)])]
        let msg = message(type: .assistant, toolCalls: calls, timestamp: nil)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isExpanded: expandAll, measurer: measurer, cache: cache,
            metrics: metrics)

        let text = MessageDisplay.displayText(of: MessageDisplay.spec(for: calls[0]))
        let content = measuredContentHeight(
            [.codeBlock(language: nil, code: text)], atWidth: 400 - 20, measurer: measurer, cache: cache)
        let expected = 32 + content + 12
        XCTAssertEqual(actual, expected)
    }

    /// Two cards in one assistant turn must be separated by the inter-card spacing exactly once —
    /// not once per card, not omitted entirely. The classic off-by-one a hand-written loop
    /// invites. Both cards use their own boundary-sensitive text so a width mistake on either
    /// one's own inset would show up here too, not only in the single-card tests above.
    func testTwoCardsInOneTurnAreSeparatedByInterCardSpacingExactlyOnce() {
        // Both cards need their own boundary-sensitive text, but a thinking card and the reply
        // that follows it now share one content-width formula (see `cardSensitiveText`'s own doc
        // comment) — the same string would land both on the same line-count boundary and hide a
        // mistake that moved one card's width without the other's, so the reply uses a second,
        // independently-sized string one line short at that same width instead of `cardSensitiveText`
        // itself.
        let replyText = text(linesAtWidth: 400 - 20, count: 99)
        let msg = message(type: .assistant, content: replyText, thinking: cardSensitiveText, timestamp: nil)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isExpanded: expandAll, measurer: measurer, cache: cache,
            metrics: metrics)

        let thinkingContent = measuredContentHeight(
            [.codeBlock(language: nil, code: cardSensitiveText)], atWidth: 400 - 20, measurer: measurer, cache: cache)
        let thinkingHeight = 32 + thinkingContent + 12
        let bubbleHeight = measuredContentHeight(
            MarkdownParser.parse(replyText), atWidth: 400 - 20, measurer: measurer, cache: cache)
        let expected = thinkingHeight + 8 + bubbleHeight

        XCTAssertEqual(actual, expected)
    }

    func testNoTimestampLineIsAddedWhenTheMessageHasNone() {
        let msg = message(type: .assistant, content: cardSensitiveText, timestamp: nil)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isExpanded: expandAll, measurer: measurer, cache: cache,
            metrics: metrics)

        let content = measuredContentHeight(
            MarkdownParser.parse(cardSensitiveText), atWidth: 400 - 20, measurer: measurer, cache: cache)
        XCTAssertEqual(actual, content)
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

        XCTAssertEqual(actual, 32)
    }

    /// A command with arguments renders unconditionally in Freddy's own bubble, with its own name
    /// as a label line above the arguments — `RelayedBubbleAddsItsOwnLabelLine` below is the same
    /// shape for a relayed prompt's "sender · group" line.
    func testACommandWithArgumentsAddsItsLabelLineAboveTheBubble() {
        let msg = message(type: .user, subtype: "command", content: "/note\n\n\(bubbleSensitiveText)", timestamp: nil)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isExpanded: expandAll, measurer: measurer, cache: cache,
            metrics: metrics)

        let content = measuredContentHeight(
            [.paragraph(InlineText(runs: [InlineRun(text: bubbleSensitiveText)]))], atWidth: 400 - 48 - 28,
            measurer: measurer,
            cache: cache)
        // 16 + 4: the command-name line's own pinned height, plus the gap above the arguments.
        let expected = content + 16 + 4 + 10
        XCTAssertEqual(actual, expected)
    }

    /// A relayed prompt draws its "sender · group" line above the body text unconditionally, even
    /// when there is no group — the same label chrome a command-with-arguments bubble carries.
    func testRelayedBubbleAddsItsOwnLabelLine() {
        let msg = message(
            type: .user, subtype: "pai_message", content: bubbleSensitiveText, originMeta: ["from": "laptop"])
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isExpanded: expandAll, measurer: measurer, cache: cache,
            metrics: metrics)

        let content = measuredContentHeight(
            [.paragraph(InlineText(runs: [InlineRun(text: bubbleSensitiveText)]))], atWidth: 400 - 48 - 28,
            measurer: measurer,
            cache: cache)
        let expected = content + 16 + 4 + 10 + 8 + 16
        XCTAssertEqual(actual, expected)
    }
}
