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
        originMeta: [String: String]? = nil
    ) -> Message {
        Message(
            id: 1, sessionId: "s", type: type, subtype: subtype, outboxId: nil, timestamp: "2026-08-29T00:00:00Z",
            content: content, thinking: thinking, toolCalls: toolCalls, toolResult: toolResult,
            hookSummary: hookSummary, tokens: nil, origin: origin, originMeta: originMeta, createdAt: nil)
    }

    private func expandAll(_: String) -> Bool { true }
    private func expandNone(_: String) -> Bool { false }

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

        let cards = TranscriptRowPlan.cards(for: msg, isExpanded: expandAll)

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

        let cards = TranscriptRowPlan.cards(for: msg, isExpanded: expandAll)

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

        let cards = TranscriptRowPlan.cards(for: msg, isExpanded: expandAll)

        XCTAssertEqual(cards.count, 1)
        guard case .toolResult(let carried) = cards[0].kind else { return XCTFail("expected a toolResult card") }
        XCTAssertEqual(carried.toolUseId, "1")
    }

    func testAToolResultMessageWithNoPayloadProducesNoCard() {
        let msg = message(type: .toolResult, toolResult: nil)
        XCTAssertTrue(TranscriptRowPlan.cards(for: msg, isExpanded: expandAll).isEmpty)
    }

    // MARK: - Collapsed vs expanded

    /// The whole point of tracking an expand key: a collapsed card must hand the composer zero
    /// blocks, not a truncated version of its content — `MessageContentLayoutComposer` measures
    /// exactly what it is given.
    func testACollapsedToolCallCarriesNoBlocksAnExpandedOneDoes() {
        let calls = [ToolCall(id: "1", name: "Bash", input: ["command": .string("ls -la")])]
        let msg = message(type: .assistant, toolCalls: calls)

        let collapsed = TranscriptRowPlan.cards(for: msg, isExpanded: expandNone)
        let expanded = TranscriptRowPlan.cards(for: msg, isExpanded: expandAll)

        XCTAssertEqual(collapsed[0].blocks.count, 0)
        XCTAssertEqual(expanded[0].blocks.count, 1)
    }

    // MARK: - Legacy and fallback shapes

    func testACaveatWrapperProducesNoCardAtAll() {
        let msg = message(
            type: .user,
            content: "<local-command-caveat>Caveat: ignore these.</local-command-caveat>")
        XCTAssertTrue(TranscriptRowPlan.cards(for: msg, isExpanded: expandAll).isEmpty)
    }

    func testAnUnparsedCommandXmlRowFallsBackToSystemRatherThanShowingTheWrapperTags() {
        let msg = message(type: .user, subtype: "command", content: "<command-name>/compact</command-name>")
        let cards = TranscriptRowPlan.cards(for: msg, isExpanded: expandAll)
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

        let cards = TranscriptRowPlan.cards(for: msg, isExpanded: expandAll)

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
        let cards = TranscriptRowPlan.cards(for: msg, isExpanded: expandAll)
        guard case .relayedBubble(_, _, let group) = cards[0].kind else { return XCTFail("expected relayedBubble") }
        XCTAssertNil(group)
    }

    /// The complaint this route exists to fix: a resend must render as Freddy's own bubble, never
    /// a generic system card captioned with his own words.
    func testAResentMessageProducesAResentUserBubbleNotAGenericSystemCard() {
        let msg = message(type: .user, subtype: "resent", content: "let's try that again")

        let cards = TranscriptRowPlan.cards(for: msg, isExpanded: expandAll)

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

        let cards = TranscriptRowPlan.cards(for: msg, isExpanded: expandAll)

        guard case .resentUserBubble(let text, let attachmentPaths) = cards[0].kind else {
            return XCTFail("expected a resentUserBubble card")
        }
        XCTAssertEqual(text, "here")
        XCTAssertEqual(attachmentPaths, [".claude/attachments/s1/a.png"])
    }

    // MARK: - Hook rows read from hookSummary, never from content

    /// `content` is `null` on a hook row — the card draws from `hookSummary` instead. A card that
    /// fell back to `content ?? ""` here would silently render an empty hook card forever.
    func testAHookRowRendersFromHookSummaryEvenThoughContentIsNil() {
        let summary = HookSummary(
            hookNames: ["PostToolUse:Bash"], hasErrors: true, errors: ["boom"], preventedContinuation: true)
        let msg = message(type: .system, subtype: "hook", content: nil, hookSummary: summary)

        let cards = TranscriptRowPlan.cards(for: msg, isExpanded: expandAll)

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
        let cards = TranscriptRowPlan.cards(for: msg, isExpanded: expandAll)
        guard case .command(let name, let args) = cards[0].kind else { return XCTFail("expected a command card") }
        XCTAssertEqual(name, "/context")
        XCTAssertNil(args)
        XCTAssertTrue(cards[0].blocks.isEmpty)
    }

    /// A command's own arguments are what Freddy typed, so they render unconditionally — this is
    /// the one bubble-shaped card that ignores the expand-preference closure entirely.
    func testACommandWithArgumentsShowsThemEvenWhenNothingIsExpanded() {
        let msg = message(type: .user, subtype: "command", content: "/loop\n\n5m /babysit-prs")
        let cards = TranscriptRowPlan.cards(for: msg, isExpanded: expandNone)
        guard case .command(_, let args) = cards[0].kind else { return XCTFail("expected a command card") }
        XCTAssertEqual(args, "5m /babysit-prs")
        XCTAssertFalse(cards[0].blocks.isEmpty)
    }
}
