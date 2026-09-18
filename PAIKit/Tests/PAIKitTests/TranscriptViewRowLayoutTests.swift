import XCTest

@testable import PAIKit

final class TranscriptViewRowLayoutTests: XCTestCase {

    private let environment = MeasurementEnvironment(sizeCategoryToken: "")
    private let metrics = MessageLayoutMetrics(blockSpacing: 4, activityLineHeight: 17, proseLineHeight: 21)
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

    /// Sized against 264 = 400 − 60 − 48 − 2×14: a bubble sits inside a row that has already
    /// spent the leading inset, the gap and the time column (60 together), and only then pays its
    /// own gutter and horizontal padding. The content width every bubble asserts on — a command's
    /// own arguments, a relayed prompt. Not Freddy's own prompt, which this file has no test for
    /// since `UserBubbleView` shares the identical formula.
    private lazy var bubbleSensitiveText = text(linesAtWidth: 400 - 136)
    /// Sized against 340 = 400 − 8 (leading inset) − 6 (the gap before the time column) − 38
    /// (the time column) − 8 (trailing inset): the width Claude's own reply wraps at, which is
    /// the whole row minus the time gutter and nothing else.
    private lazy var proseSensitiveText = text(linesAtWidth: 400 - 60)
    /// Sized against 310 = 340 − 2 (the rail) − 22 (the marker column) − 6 (the gap after it):
    /// an activity row's body sits inside the grid, so it is narrower than prose by exactly the
    /// two columns to its left.
    private lazy var cardSensitiveText = text(linesAtWidth: 400 - 90)

    private func message(
        type: MessageType,
        subtype: String? = nil,
        content: String? = nil,
        thinking: String? = nil,
        toolCalls: [ToolCall]? = nil,
        toolResult: ToolResult? = nil,
        originMeta: [String: String]? = nil,
        timestamp: String? = "2026-08-29T00:00:00Z",
        notificationMarker: String? = nil
    ) -> Message {
        Message(
            id: 1, sessionId: "s", type: type, subtype: subtype, outboxId: nil, timestamp: timestamp,
            content: content, thinking: thinking, toolCalls: toolCalls, toolResult: toolResult,
            hookSummary: nil, tokens: nil, origin: nil, originMeta: originMeta,
            notificationMarker: notificationMarker, createdAt: nil)
    }

    private func revealAll(_: Int) -> Bool { true }
    private func revealNone(_: Int) -> Bool { false }

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
                for: msg, width: width, environment: environment, isRevealed: revealAll, measurer: measurer,
                cache: cache,
                metrics: metrics))
    }

    // MARK: - Prose

    /// Claude's reply is not a bubble and not inside the activity grid: it wraps at the whole row
    /// minus the time gutter, and carries only its own vertical padding. The literals here are
    /// never `TranscriptRowMetrics`'s own constants, so a mutation of one moves what the code
    /// measures at without moving this expectation.
    func testAnAssistantReplyIsProseAtFullWidthWithItsOwnPadding() {
        let msg = message(type: .assistant, content: proseSensitiveText)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isRevealed: revealAll, measurer: measurer, cache: cache,
            metrics: metrics)

        let content = measuredContentHeight(
            MarkdownParser.parse(proseSensitiveText), atWidth: 400 - 60, measurer: measurer, cache: cache)
        // 10 above and 10 below. No timestamp line: the time shares the row's own trailing column.
        XCTAssertEqual(actual, content + 20)
    }

    /// The timestamp costs no height at all now — it rides the trailing column. A row with one and
    /// a row without must therefore measure identically, which is the whole point of moving it.
    func testATimestampCostsNoHeight() {
        let withStamp = message(type: .assistant, content: proseSensitiveText)
        let withoutStamp = message(type: .assistant, content: proseSensitiveText, timestamp: nil)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        func height(_ msg: Message) -> Double? {
            TranscriptRowLayout.height(
                for: msg, width: width, environment: environment, isRevealed: revealAll, measurer: measurer,
                cache: cache, metrics: metrics)
        }

        XCTAssertEqual(height(withStamp), height(withoutStamp))
    }

    // MARK: - Activity rows

    /// An activity row is its padding, one label line, its body and — only when something was cut
    /// — a trailer. Revealed, nothing is cut, so this is the width-sensitive case: the body is
    /// measured at the grid's own narrower width, not at the row's.
    func testARevealedToolCallIsPaddingLabelAndBodyAtTheGridWidth() {
        let calls = [ToolCall(id: "1", name: "Bash", input: ["command": .string(cardSensitiveText)])]
        let msg = message(type: .assistant, toolCalls: calls, timestamp: nil)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isRevealed: revealAll, measurer: measurer, cache: cache,
            metrics: metrics)

        let text = MessageDisplay.displayText(of: MessageDisplay.spec(for: calls[0]))
        let content = measuredContentHeight(
            [.codeBlock(language: nil, code: text)], atWidth: 400 - 90, measurer: measurer, cache: cache)
        // 3 above and 3 below, plus the one label line the row always reserves.
        XCTAssertEqual(actual, 6 + 17 + content)
    }

    /// The same call unrevealed is bounded and pays for a trailer. A body far longer than the
    /// clamp could ever draw is trimmed before it is measured, so what reaches the composer here
    /// is the headroom rather than the whole command — and the row is truncated because of that
    /// trim whether or not the height cap also bit, which is the point: how many characters a
    /// line fits is a property of the font, and text must never be dropped with nothing saying so.
    func testAnUnrevealedToolCallIsBoundedAndPaysForItsTrailer() {
        let calls = [ToolCall(id: "1", name: "Bash", input: ["command": .string(cardSensitiveText)])]
        let msg = message(type: .assistant, toolCalls: calls, timestamp: nil)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isRevealed: revealNone, measurer: measurer, cache: cache,
            metrics: metrics)

        // 2 × 200 characters of headroom, measured at the grid width, then the trailer the trim
        // itself earns.
        let content = measuredContentHeight(
            [.codeBlock(language: nil, code: String(cardSensitiveText.prefix(400)))], atWidth: 400 - 90,
            measurer: measurer, cache: cache)
        XCTAssertEqual(actual, 6 + 17 + content + 17)
    }

    /// A body that fits inside its cap is not truncated, so it reserves no trailer — the case a
    /// formula that always added one would get wrong, and the one that is most of the transcript.
    func testAShortBodyIsNotTruncatedAndReservesNoTrailer() {
        let calls = [ToolCall(id: "1", name: "Bash", input: ["command": .string("ls")])]
        let msg = message(type: .assistant, toolCalls: calls, timestamp: nil)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isRevealed: revealNone, measurer: measurer, cache: cache,
            metrics: metrics)

        let content = measuredContentHeight(
            [.codeBlock(language: nil, code: "ls")], atWidth: 400 - 90, measurer: measurer, cache: cache)
        XCTAssertEqual(actual, 6 + 17 + content)
    }

    /// A row whose body is empty still reserves its label line — a system notice with nothing to
    /// report is one line of row, never zero.
    func testASystemRowWithAnEmptyBodyIsStillOneLabelLine() {
        let msg = message(type: .system, timestamp: nil)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isRevealed: revealAll, measurer: measurer, cache: cache,
            metrics: metrics)

        XCTAssertEqual(actual, 6 + 17)
    }

    /// Proves `.notifyReply` measures in the activity register rather than in a plausible-looking
    /// but wrong one (a bubble's gutter-and-double-padding formula, say) — a mistake that would
    /// still compile, since every arm is exhaustive either way, and would only show up as a
    /// systematically wrong scroll position on a real device.
    func testANotifyReplyMeasuresAsAnActivityRow() {
        let yaml =
            "status: ok\nmarker: pai-notify:x\ntitle: \(cardSensitiveText)\nbody: a short body\n"
        let result = ToolResult(toolUseId: "1", toolName: "Bash", content: yaml, isError: false)
        let msg = message(
            type: .toolResult, toolResult: result, timestamp: nil, notificationMarker: "pai-notify:x")
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isRevealed: revealAll, measurer: measurer, cache: cache,
            metrics: metrics)

        let content = measuredContentHeight(
            [
                .paragraph(InlineText(runs: [InlineRun(text: cardSensitiveText)])),
                .paragraph(InlineText(runs: [InlineRun(text: "a short body")])),
            ], atWidth: 400 - 90, measurer: measurer, cache: cache)
        // Never bounded, so never a trailer, however long the body is.
        XCTAssertEqual(actual, 6 + 17 + content)
    }

    /// Two cards in one turn sit flush against each other: the gap is each row's own padding now,
    /// not a constant between the pair, which is what lets a run of activity rows share one rail.
    /// Both cards use their own boundary-sensitive text so a width mistake on either one's own
    /// inset shows up here too, not only in the single-card tests above.
    func testTwoCardsInOneTurnAreFlushWithNoSpacingBetweenThem() {
        let msg = message(type: .assistant, content: proseSensitiveText, thinking: cardSensitiveText, timestamp: nil)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isRevealed: revealAll, measurer: measurer, cache: cache,
            metrics: metrics)

        let thinkingContent = measuredContentHeight(
            [.preformattedText(cardSensitiveText)], atWidth: 400 - 90, measurer: measurer, cache: cache)
        let thinkingHeight = 6 + 17 + thinkingContent
        let proseHeight =
            measuredContentHeight(
                MarkdownParser.parse(proseSensitiveText), atWidth: 400 - 60, measurer: measurer, cache: cache) + 20

        XCTAssertEqual(actual, thinkingHeight + proseHeight)
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
            for: msg, width: width, environment: environment, isRevealed: revealAll, measurer: measurer, cache: cache,
            metrics: metrics)

        // 12: the row's own padding. Two 22pt chips, one 6pt gap between them — no text bubble,
        // so no bubble padding either.
        XCTAssertEqual(actual, 12 + 2 * 22 + 6)
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
            for: msg, width: width, environment: environment, isRevealed: revealAll, measurer: measurer, cache: cache,
            metrics: metrics)

        let content = measuredContentHeight(
            [.paragraph(InlineText(runs: [InlineRun(text: bubbleSensitiveText)]))], atWidth: 400 - 136,
            measurer: measurer, cache: cache)
        // 12: the row's padding. 10: the text bubble's own vertical padding. 44: two 22pt chips.
        // 12: two 6pt gaps (bubble → first chip, first chip → second).
        XCTAssertEqual(actual, 12 + content + 10 + 44 + 12)
    }

    // MARK: - Assistant file markers

    /// Mirrors the user-bubble attachment tests just above: a `pai-file:` marker becomes its own
    /// fixed-height chip below the reply, gapped the same way — but unlike a user attachment, the
    /// marker LINE stays in the rendered text too, since the message is never rewritten for this
    /// (`MessageRouting.extractFilePaths`), so the measured content includes it.
    func testAssistantFileMarkersAddChipHeightsAndGapsBelowTheUnmodifiedProse() {
        let messageContent = "\(proseSensitiveText)\n\npai-file: /tmp/one.png\npai-file: /tmp/two.png"
        let msg = message(type: .assistant, content: messageContent, timestamp: nil)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isRevealed: revealAll, measurer: measurer, cache: cache,
            metrics: metrics)

        let content = measuredContentHeight(
            MarkdownParser.parse(messageContent), atWidth: 400 - 60, measurer: measurer, cache: cache)
        // 20: the prose row's own padding. 44: two 22pt chips. 12: two 6pt gaps.
        XCTAssertEqual(actual, 20 + content + 44 + 12)
    }

    // MARK: - Bubbles a person is behind

    /// An argument-free command degrades to a compact line naming it and nothing else.
    func testACommandWithNoArgumentsIsOneLabelLineInABubble() {
        let msg = message(type: .user, subtype: "command", content: "/context\n\n", timestamp: nil)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isRevealed: revealAll, measurer: measurer, cache: cache,
            metrics: metrics)

        // 12: the row's padding. 16: the name line. 10: the bubble's own vertical padding.
        XCTAssertEqual(actual, 12 + 16 + 10)
    }

    /// A command with arguments renders unconditionally in Freddy's own bubble, with its own name
    /// as a label line above the arguments — `RelayedBubbleAddsItsOwnLabelLine` below is the same
    /// shape for a relayed prompt's "sender · group" line.
    func testACommandWithArgumentsAddsItsLabelLineAboveTheBubble() {
        let msg = message(type: .user, subtype: "command", content: "/note\n\n\(bubbleSensitiveText)", timestamp: nil)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isRevealed: revealAll, measurer: measurer, cache: cache,
            metrics: metrics)

        let content = measuredContentHeight(
            [.paragraph(InlineText(runs: [InlineRun(text: bubbleSensitiveText)]))], atWidth: 400 - 136,
            measurer: measurer,
            cache: cache)
        // 12: the row's padding. 16 + 4: the command-name line's own pinned height, plus the gap
        // above the arguments. 10: the bubble's own vertical padding.
        XCTAssertEqual(actual, 12 + content + 16 + 4 + 10)
    }

    /// A relayed prompt draws its "sender · group" line above the body text unconditionally, even
    /// when there is no group — the same label chrome a command-with-arguments bubble carries.
    func testRelayedBubbleAddsItsOwnLabelLine() {
        let msg = message(
            type: .user, subtype: "pai_message", content: bubbleSensitiveText, originMeta: ["from": "laptop"])
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isRevealed: revealAll, measurer: measurer, cache: cache,
            metrics: metrics)

        let content = measuredContentHeight(
            [.paragraph(InlineText(runs: [InlineRun(text: bubbleSensitiveText)]))], atWidth: 400 - 136,
            measurer: measurer,
            cache: cache)
        XCTAssertEqual(actual, 12 + content + 16 + 4 + 10)
    }

    /// The resend affordance draws its "Resent" label line above the body text unconditionally,
    /// the same label chrome a relayed prompt's own bubble carries — the mirror shape of
    /// `testRelayedBubbleAddsItsOwnLabelLine` just above.
    func testResentUserBubbleAddsItsOwnLabelLine() {
        let msg = message(type: .user, subtype: "resent", content: bubbleSensitiveText)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isRevealed: revealAll, measurer: measurer, cache: cache,
            metrics: metrics)

        let content = measuredContentHeight(
            [.paragraph(InlineText(runs: [InlineRun(text: bubbleSensitiveText)]))], atWidth: 400 - 136,
            measurer: measurer,
            cache: cache)
        XCTAssertEqual(actual, 12 + content + 16 + 4 + 10)
    }

    /// An attachment-only resend (no text at all) draws no bubble and no "Resent" label — mirrors
    /// `testAttachmentsWithNoTextAddOnlyChipHeightsAndTheGapsBetweenThem` above, and matches the
    /// web's own `{text && (…)}` wrapping the whole labelled bubble.
    func testResentUserBubbleWithNoTextAddsOnlyChipHeightsAndNoLabelChrome() {
        let msg = message(
            type: .user, subtype: "resent",
            content: ".claude/attachments/a/one.png .claude/attachments/a/two.png", timestamp: nil)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isRevealed: revealAll, measurer: measurer, cache: cache,
            metrics: metrics)

        // Two 22pt chips, one 6pt gap between them — no bubble, no label, no bubble padding.
        XCTAssertEqual(actual, 12 + 2 * 22 + 6)
    }

    /// Attachments on a resend gap after the labelled bubble the same way an ordinary user
    /// message's chips do — the label is always present, so the extra gap applies once more,
    /// between the bubble and the first chip.
    func testResentUserBubbleWithAttachmentsGapsAfterTheLabelledBubble() {
        let msg = message(
            type: .user, subtype: "resent",
            content: "\(bubbleSensitiveText)\n\n.claude/attachments/a/one.png .claude/attachments/a/two.png",
            timestamp: nil)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let actual = TranscriptRowLayout.height(
            for: msg, width: width, environment: environment, isRevealed: revealAll, measurer: measurer, cache: cache,
            metrics: metrics)

        let content = measuredContentHeight(
            [.paragraph(InlineText(runs: [InlineRun(text: bubbleSensitiveText)]))], atWidth: 400 - 136,
            measurer: measurer,
            cache: cache)
        // content + label chrome (16 + 4) + bubble padding (10), then two 22pt chips and two 6pt
        // gaps (bubble → first chip, first chip → second).
        XCTAssertEqual(actual, 12 + (content + 16 + 4 + 10) + 44 + 12)
    }
}
