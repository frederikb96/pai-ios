import XCTest

@testable import PAIKit

final class TranscriptViewRowPlanTests: XCTestCase {

    private func message(
        type: MessageType,
        subtype: String? = nil,
        content: String? = nil,
        thinking: String? = nil,
        toolCalls: [ToolCall]? = nil,
        toolResult: ToolResult? = nil,
        hookSummary: HookSummary? = nil,
        origin: String? = nil,
        originMeta: [String: String]? = nil,
        notificationMarker: String? = nil
    ) -> Message {
        Message(
            id: 1, sessionId: "s", type: type, subtype: subtype, outboxId: nil, timestamp: "2026-08-29T00:00:00Z",
            content: content, thinking: thinking, toolCalls: toolCalls, toolResult: toolResult,
            hookSummary: hookSummary, tokens: nil, origin: origin, originMeta: originMeta,
            notificationMarker: notificationMarker, createdAt: nil)
    }

    private func revealAll(_: Int) -> Bool { true }
    private func revealNone(_: Int) -> Bool { false }

    // MARK: - Assistant turns: order and completeness

    /// The exact ordering that makes an assistant turn readable: think, then act, then reply.
    /// A refactor that reordered the loop, or dropped the thinking/bubble cards when tool calls
    /// are also present, would still produce *a* plan — this is the test that notices it produced
    /// the wrong one.
    func testAssistantTurnOrdersThinkingThenEachToolCallThenTheReply() {
        let calls = [
            ToolCall(id: "1", name: "Bash", input: ["command": .string("ls")]),
            ToolCall(id: "2", name: "Read", input: ["file_path": .string("/tmp/a")]),
        ]
        let msg = message(type: .assistant, content: "Done.", thinking: "Let me check.", toolCalls: calls)

        let cards = TranscriptRowPlan.cards(for: msg, isRevealed: revealAll)

        XCTAssertEqual(cards.count, 4)
        guard case .thinking = cards[0].kind else { return XCTFail("expected thinking first, got \(cards[0].kind)") }
        guard case .toolCall(let first) = cards[1].kind else { return XCTFail("expected the Bash call second") }
        XCTAssertEqual(first.name, "Bash")
        guard case .toolCall(let second) = cards[2].kind else { return XCTFail("expected the Read call third") }
        XCTAssertEqual(second.name, "Read")
        guard case .assistantBubble(let text, let filePaths) = cards[3].kind else {
            return XCTFail("expected the reply last")
        }
        XCTAssertEqual(text, "Done.")
        XCTAssertEqual(filePaths, [])
    }

    /// The marker line is never stripped from `text` — `filePaths` is purely additive, per
    /// Freddy's own rule that a `pai-file:` chip renders below the message, not in place of it.
    func testAssistantBubbleCarriesFilePathsAlongsideTheUnmodifiedText() {
        let content = "Here's the screenshot.\n\npai-file: /tmp/shot.png"
        let msg = message(type: .assistant, content: content)

        let cards = TranscriptRowPlan.cards(for: msg, isRevealed: revealAll)

        XCTAssertEqual(cards.count, 1)
        guard case .assistantBubble(let text, let filePaths) = cards[0].kind else {
            return XCTFail("expected an assistant bubble, got \(cards[0].kind)")
        }
        XCTAssertEqual(text, content)
        XCTAssertEqual(filePaths, ["/tmp/shot.png"])
    }

    /// A tool call and its result never arrive on the same `Message` — they are two separate rows
    /// in the transcript. This is the trap the report flagged as the sharpest one: a plan that
    /// paired them would typecheck and only fail once a real result never showed up next to a
    /// card expecting one.
    func testAToolResultProducesItsOwnCardNeverPairedWithACall() {
        let result = ToolResult(toolUseId: "1", toolName: "Bash", content: "ok", isError: false)
        let msg = message(type: .toolResult, toolResult: result)

        let cards = TranscriptRowPlan.cards(for: msg, isRevealed: revealAll)

        XCTAssertEqual(cards.count, 1)
        guard case .toolResult(let carried) = cards[0].kind else { return XCTFail("expected a toolResult card") }
        XCTAssertEqual(carried.toolUseId, "1")
    }

    func testAToolResultMessageWithNoPayloadProducesNoCard() {
        let msg = message(type: .toolResult, toolResult: nil)
        XCTAssertTrue(TranscriptRowPlan.cards(for: msg, isRevealed: revealAll).isEmpty)
    }

    // MARK: - A notify tool_result, the card a notification jump lands on

    /// Real `serialize_response()` output (`backend/src/pai_cloud/mcp_serializer.py`) for a
    /// successful `notify` call — same text whether the reply reached the transcript as a native
    /// MCP tool_result or a Bash tool_result wrapping `mcp-call`'s stdout.
    private let notifyReplyContent =
        "status: ok\nsent: true\nnotification_id: 11111111-1111-1111-1111-111111111111\n"
        + "marker: pai-notify:11111111-1111-1111-1111-111111111111\n"
        + "title: Deploy finished\nbody: The release is live.\n"

    func testAToolResultCarryingAMarkerBecomesANotifyReplyCard() {
        let result = ToolResult(toolUseId: "1", toolName: "Bash", content: notifyReplyContent, isError: false)
        let msg = message(
            type: .toolResult, toolResult: result,
            notificationMarker: "pai-notify:11111111-1111-1111-1111-111111111111")

        let cards = TranscriptRowPlan.cards(for: msg, isRevealed: revealAll)

        XCTAssertEqual(cards.count, 1)
        guard case .notifyReply(let title, let body) = cards[0].kind else {
            return XCTFail("expected a notifyReply card, got \(cards[0].kind)")
        }
        XCTAssertEqual(title, "Deploy finished")
        XCTAssertEqual(body, "The release is live.")
        // Always shown whole, unlike an ordinary toolResult card: there is nothing to clip that
        // would not just repeat the title.
        XCTAssertFalse(cards[0].preview.isBounded)
    }

    func testAMarkedResultFallsBackToTheOrdinaryToolResultCardWhenTheReplyTextCannotBeParsed() {
        // A single-quoted value can fold across lines two ways: a lone break is a width-wrap fold
        // (rejoined with a space), but two in a row encode a literal embedded newline — the one
        // shape `parseNotifyReply` still cannot reconstruct, so this stays the genuine fallback case.
        let unparseable =
            "status: ok\nmarker: pai-notify:x\ntitle: Deploy finished\nbody: 'line one\n\n  line two'\n"
        let result = ToolResult(toolUseId: "1", toolName: "Bash", content: unparseable, isError: false)
        let msg = message(type: .toolResult, toolResult: result, notificationMarker: "pai-notify:x")

        let cards = TranscriptRowPlan.cards(for: msg, isRevealed: revealAll)

        XCTAssertEqual(cards.count, 1)
        guard case .toolResult(let carried) = cards[0].kind else {
            return XCTFail("expected the generic toolResult fallback, got \(cards[0].kind)")
        }
        XCTAssertEqual(carried.toolUseId, "1")
    }

    func testAnOrdinaryToolResultWithNoMarkerIsNeverTreatedAsANotifyReply() {
        let result = ToolResult(toolUseId: "1", toolName: "Read", content: notifyReplyContent, isError: false)
        let msg = message(type: .toolResult, toolResult: result, notificationMarker: nil)

        let cards = TranscriptRowPlan.cards(for: msg, isRevealed: revealAll)

        guard case .toolResult = cards[0].kind else {
            return XCTFail("a result with no marker must never become a notifyReply card")
        }
    }

    // MARK: - Bounded vs revealed

    /// A bounded card still carries its body — the bound is a clip, not an omission, which is
    /// what lets the row say whether anything was actually cut. What it must NOT carry is the
    /// whole of an unbounded one: a body far longer than the clamp can ever draw is cut to a
    /// headroom first, so a thought of ten thousand characters is not laid out to show two lines.
    func testABoundedBodyKeepsWhatItShowsAndNoMoreThanItCouldEverDraw() {
        let huge = String(repeating: "x", count: 10_000)
        let calls = [ToolCall(id: "1", name: "Bash", input: ["command": .string(huge)])]
        let msg = message(type: .assistant, toolCalls: calls)

        let bounded = TranscriptRowPlan.cards(for: msg, isRevealed: revealNone)
        let revealed = TranscriptRowPlan.cards(for: msg, isRevealed: revealAll)

        XCTAssertEqual(bounded[0].blocks.count, 1)
        XCTAssertEqual(revealed[0].blocks.count, 1)
        XCTAssertLessThan(bounded[0].blocks[0].plainText.count, 1_000)
        XCTAssertEqual(revealed[0].blocks[0].plainText.count, 10_000)
    }

    /// A body short enough to fit is never cut, however the bound is expressed — the case that is
    /// most of the transcript, and the one a headroom applied unconditionally would damage.
    func testAShortBodyIsCarriedWholeEvenWhileBounded() {
        let calls = [ToolCall(id: "1", name: "Bash", input: ["command": .string("ls -la")])]
        let msg = message(type: .assistant, toolCalls: calls)

        let bounded = TranscriptRowPlan.cards(for: msg, isRevealed: revealNone)

        XCTAssertEqual(bounded[0].blocks[0].plainText, "ls -la")
    }

    // MARK: - Legacy and fallback shapes

    func testACaveatWrapperProducesNoCardAtAll() {
        let msg = message(
            type: .user,
            content: "<local-command-caveat>Caveat: ignore these.</local-command-caveat>")
        XCTAssertTrue(TranscriptRowPlan.cards(for: msg, isRevealed: revealAll).isEmpty)
    }

    func testAnUnparsedCommandXmlRowFallsBackToSystemRatherThanShowingTheWrapperTags() {
        let msg = message(type: .user, subtype: "command", content: "<command-name>/compact</command-name>")
        let cards = TranscriptRowPlan.cards(for: msg, isRevealed: revealAll)
        XCTAssertEqual(cards.count, 1)
        guard case .system = cards[0].kind else {
            return XCTFail("expected a system fallback card, got \(cards[0].kind)")
        }
    }

    /// `MessageRouting.route(for:)` has no case for `pai_message` — see this file's own doc
    /// comment on `TranscriptRowPlan.cards(for:isExpanded:)`. This test is the guard against that
    /// gap silently regressing further: a relayed message must never fall through to a plain
    /// system card.
    func testARelayedMessageProducesARelayedBubbleNotAGenericSystemCard() {
        let msg = message(
            type: .user, subtype: "pai_message", content: "Repository setup finished.",
            origin: "agent", originMeta: ["from": "aria", "group": "pai-ios-build"])

        let cards = TranscriptRowPlan.cards(for: msg, isRevealed: revealAll)

        XCTAssertEqual(cards.count, 1)
        guard case .relayedBubble(let text, let sender, let group) = cards[0].kind else {
            return XCTFail("expected a relayedBubble card, got \(cards[0].kind)")
        }
        XCTAssertEqual(text, "Repository setup finished.")
        XCTAssertEqual(sender, "aria")
        XCTAssertEqual(group, "pai-ios-build")
    }

    /// The group pill only ever shows when the message was actually relayed by another agent —
    /// a `pai_message` row with no `origin` still gets the coloured bubble, just without a group.
    func testARelayedMessageWithNoAgentOriginCarriesNoGroup() {
        let msg = message(
            type: .user, subtype: "pai_message", content: "hi", originMeta: ["from": "aria", "group": "x"])
        let cards = TranscriptRowPlan.cards(for: msg, isRevealed: revealAll)
        guard case .relayedBubble(_, _, let group) = cards[0].kind else { return XCTFail("expected relayedBubble") }
        XCTAssertNil(group)
    }

    /// The complaint this route exists to fix: a resend must render as Freddy's own bubble, never
    /// a generic system card captioned with his own words.
    func testAResentMessageProducesAResentUserBubbleNotAGenericSystemCard() {
        let msg = message(type: .user, subtype: "resent", content: "let's try that again")

        let cards = TranscriptRowPlan.cards(for: msg, isRevealed: revealAll)

        XCTAssertEqual(cards.count, 1)
        guard case .resentUserBubble(let text, let attachmentPaths) = cards[0].kind else {
            return XCTFail("expected a resentUserBubble card, got \(cards[0].kind)")
        }
        XCTAssertEqual(text, "let's try that again")
        XCTAssertEqual(attachmentPaths, [])
    }

    /// Attachments on a resend are extracted the same way an ordinary user message's are — an
    /// interrupted send can carry them too.
    func testAResentMessageWithAttachmentsExtractsThemLikeAnOrdinaryUserMessage() {
        let msg = message(
            type: .user, subtype: "resent", content: "here\n\n.claude/attachments/s1/a.png")

        let cards = TranscriptRowPlan.cards(for: msg, isRevealed: revealAll)

        guard case .resentUserBubble(let text, let attachmentPaths) = cards[0].kind else {
            return XCTFail("expected a resentUserBubble card")
        }
        XCTAssertEqual(text, "here")
        XCTAssertEqual(attachmentPaths, [".claude/attachments/s1/a.png"])
    }

    /// The Thinking card's own block is `.preformattedText`, never `.codeBlock` — the exact
    /// distinction that stops it scrolling sideways instead of wrapping. A tool call's own body
    /// is unaffected and still gets `.codeBlock`.
    func testThinkingCardBlockIsPreformattedTextNotCodeBlock() {
        let calls = [ToolCall(id: "1", name: "Bash", input: ["command": .string("ls")])]
        let msg = message(type: .assistant, thinking: "Let me check.", toolCalls: calls)

        let cards = TranscriptRowPlan.cards(for: msg, isRevealed: revealAll)

        guard case .preformattedText(let text) = cards[0].blocks.first else {
            return XCTFail("expected the thinking card's block to be .preformattedText, got \(cards[0].blocks)")
        }
        XCTAssertEqual(text, "Let me check.")
        guard case .codeBlock = cards[1].blocks.first else {
            return XCTFail("expected the tool call's own block to stay .codeBlock")
        }
    }

    /// A thought wraps rather than scrolling sideways — it is prose that happens to be one
    /// enormous source line, so the block kind is the wrapping one whether or not it is bounded.
    func testAThinkingCardWrapsItsTextWhicheverStateItIsIn() {
        let msg = message(type: .assistant, thinking: "Let me check.")

        for cards in [
            TranscriptRowPlan.cards(for: msg, isRevealed: revealNone),
            TranscriptRowPlan.cards(for: msg, isRevealed: revealAll),
        ] {
            guard case .preformattedText(let text) = cards[0].blocks.first else {
                return XCTFail("expected a wrapping block, got \(String(describing: cards[0].blocks.first))")
            }
            XCTAssertEqual(text, "Let me check.")
        }
    }

    // MARK: - Hook rows read from hookSummary, never from content

    /// `content` is `null` on a hook row — the card draws from `hookSummary` instead. A card that
    /// fell back to `content ?? ""` here would silently render an empty hook card forever.
    func testAHookRowRendersFromHookSummaryEvenThoughContentIsNil() {
        let summary = HookSummary(
            hookNames: ["PostToolUse:Bash"], hasErrors: true, errors: ["boom"], preventedContinuation: true)
        let msg = message(type: .system, subtype: "hook", content: nil, hookSummary: summary)

        let cards = TranscriptRowPlan.cards(for: msg, isRevealed: revealAll)

        XCTAssertEqual(cards.count, 1)
        let block = cards[0].blocks.first
        guard case .codeBlock(_, let code) = block else { return XCTFail("expected a codeBlock body") }
        XCTAssertTrue(code.contains("PostToolUse:Bash"))
        XCTAssertTrue(code.contains("boom"))
        XCTAssertTrue(code.contains("Prevented continuation"))
    }

    // MARK: - Commands

    func testACommandWithNoArgumentsCarriesNoBlocksAndNilArgs() {
        let msg = message(type: .user, subtype: "command", content: "/context\n\n")
        let cards = TranscriptRowPlan.cards(for: msg, isRevealed: revealAll)
        guard case .command(let name, let args) = cards[0].kind else { return XCTFail("expected a command card") }
        XCTAssertEqual(name, "/context")
        XCTAssertNil(args)
        XCTAssertTrue(cards[0].blocks.isEmpty)
    }

    /// A command's own arguments are what Freddy typed, so they render unconditionally — this is
    /// the one bubble-shaped card that ignores the expand-preference closure entirely.
    func testACommandWithArgumentsShowsThemEvenWhenNothingIsExpanded() {
        let msg = message(type: .user, subtype: "command", content: "/loop\n\n5m /babysit-prs")
        let cards = TranscriptRowPlan.cards(for: msg, isRevealed: revealNone)
        guard case .command(_, let args) = cards[0].kind else { return XCTFail("expected a command card") }
        XCTAssertEqual(args, "5m /babysit-prs")
        XCTAssertFalse(cards[0].blocks.isEmpty)
    }
}
