import XCTest

@testable import PAIKit

/// Covers `MessageRouting.route(for:)`'s branch order — several branches exist only because an
/// earlier one failed to match, so the risk here is a reordering or a loosened guard silently
/// making an unreachable branch reachable (or vice versa) — plus the attachment-path and
/// expand-key logic that sits beside it.
final class TranscriptMessageRoutingTests: XCTestCase {

    private func message(
        type: MessageType,
        subtype: String? = nil,
        content: String? = nil,
        toolResult: ToolResult? = nil
    ) -> Message {
        Message(
            id: 1, sessionId: "s1", type: type, subtype: subtype, outboxId: nil, timestamp: nil,
            content: content, thinking: nil, toolCalls: nil, toolResult: toolResult, hookSummary: nil,
            tokens: nil, origin: nil, originMeta: nil, createdAt: nil
        )
    }

    // MARK: - Routing order

    func testSystemTypeRoutesToSystemEvenWithASubtype() {
        XCTAssertEqual(MessageRouting.route(for: message(type: .system, subtype: "hook")), .system)
    }

    func testToolResultWithAPayloadRoutesToToolResult() {
        let result = ToolResult(toolUseId: "t1", toolName: "Bash", content: "ok", isError: false)
        XCTAssertEqual(MessageRouting.route(for: message(type: .toolResult, toolResult: result)), .toolResult)
    }

    /// `type == 'tool_result'` with no result payload is not exercised by the web (every real row
    /// carries one), but the guard exists — a row missing it must degrade to nothing rather than
    /// route to a case whose associated data does not exist.
    func testToolResultWithNoPayloadRoutesToNone() {
        XCTAssertEqual(MessageRouting.route(for: message(type: .toolResult, toolResult: nil)), .none)
    }

    func testLegacyCaveatWrapperRendersNothing() {
        let route = MessageRouting.route(
            for: message(type: .user, content: "<local-command-caveat>ignored</local-command-caveat>"))
        XCTAssertEqual(route, .hidden)
    }

    func testLegacyWrapperWithEmptyInnerBodyRendersNothing() {
        let route = MessageRouting.route(
            for: message(type: .user, content: "<local-command-stdout></local-command-stdout>"))
        XCTAssertEqual(route, .hidden)
    }

    func testLegacyStdoutWrapperSurfacesItsInnerTextAsCommandOutput() {
        let route = MessageRouting.route(
            for: message(type: .user, content: "<local-command-stdout>build ok</local-command-stdout>"))
        XCTAssertEqual(route, .legacyCommandOutput(content: "build ok"))
    }

    func testOrdinaryUserMessageWithNoSubtypeAndNoLegacyWrapperRoutesToUser() {
        let route = MessageRouting.route(for: message(type: .user, content: "hello there"))
        XCTAssertEqual(route, .user(text: "hello there", attachmentPaths: []))
    }

    func testAgentMessageSubtypeRoutesToAgentMessage() {
        XCTAssertEqual(
            MessageRouting.route(for: message(type: .user, subtype: "agent_message", content: "x")), .agentMessage)
    }

    func testCleanCommandSubtypeRoutesToCommand() {
        let route = MessageRouting.route(for: message(type: .user, subtype: "command", content: "review\n\n--verbose"))
        XCTAssertEqual(route, .command)
    }

    /// The order-dependent trap: a `command` row whose content is still raw XML must fall through
    /// PAST the command branch to the generic system fallback, not render as (or crash trying to
    /// render as) a clean command card.
    func testCommandSubtypeWithUnparsedXmlFallsBackToSystemFallbackNotCommand() {
        let route = MessageRouting.route(
            for: message(type: .user, subtype: "command", content: "<command-name>review</command-name>"))
        XCTAssertEqual(route, .systemFallback(subtype: "command", content: "<command-name>review</command-name>"))
    }

    func testAnyOtherUserSubtypeRoutesToSystemFallback() {
        let route = MessageRouting.route(
            for: message(type: .user, subtype: "compact", content: "Conversation compacted"))
        XCTAssertEqual(route, .systemFallback(subtype: "compact", content: "Conversation compacted"))
    }

    func testAssistantTypeRoutesToAssistant() {
        XCTAssertEqual(MessageRouting.route(for: message(type: .assistant, content: "hi")), .assistant)
    }

    /// A message type this build predates must degrade to nothing rather than crash a switch or
    /// silently fall into an unrelated branch.
    func testUnrecognizedTypeRoutesToNone() {
        XCTAssertEqual(MessageRouting.route(for: message(type: .unrecognized("future_type"))), .none)
    }

    // MARK: - Attachment extraction

    func testAttachmentBlockIsStrippedWhenEveryTokenMatches() {
        let content = "here you go\n\n.claude/attachments/sess1/a.png .claude/attachments/sess1/b.png"
        let (text, paths) = MessageRouting.extractAttachmentPaths(content)
        XCTAssertEqual(text, "here you go")
        XCTAssertEqual(paths, [".claude/attachments/sess1/a.png", ".claude/attachments/sess1/b.png"])
    }

    /// One token in the trailing block that does not match the attachment shape must fail the
    /// whole block, not strip the tokens that do match and leave the rest as stray text.
    func testAttachmentBlockIsLeftAloneWhenOneTokenDoesNotMatch() {
        let content = "here you go\n\n.claude/attachments/sess1/a.png not-a-path"
        let (text, paths) = MessageRouting.extractAttachmentPaths(content)
        XCTAssertEqual(text, content)
        XCTAssertEqual(paths, [])
    }

    /// An images-only send has no leading text at all — its whole prompt is the joined paths,
    /// with no `"\n\n"` separator anywhere. That must still be recognised, with the returned
    /// text coming back empty rather than the routing falling through to "not an attachment".
    func testAttachmentOnlyContentWithNoSeparatorStillExtracts() {
        let content = ".claude/attachments/sess1/a.png"
        let (text, paths) = MessageRouting.extractAttachmentPaths(content)
        XCTAssertEqual(text, "")
        XCTAssertEqual(paths, [content])
    }

    func testPlainTextWithNoAttachmentShapedTokensIsReturnedUnchanged() {
        let content = "just a normal message\n\nwith two paragraphs"
        let (text, paths) = MessageRouting.extractAttachmentPaths(content)
        XCTAssertEqual(text, content)
        XCTAssertEqual(paths, [])
    }

    // MARK: - File markers

    func testFileMarkerPathIsFoundAndTheMarkerLineIsNeverRemoved() {
        let content = "Here's the screenshot.\n\npai-file: /home/frederik/.tmp/shot.png"
        XCTAssertEqual(MessageRouting.extractFilePaths(content), ["/home/frederik/.tmp/shot.png"])
    }

    func testMultipleMarkersAreFoundInOrderAndDeduplicated() {
        let content = "pai-file: /tmp/a.png\npai-file: /tmp/b.png\npai-file: /tmp/a.png"
        XCTAssertEqual(MessageRouting.extractFilePaths(content), ["/tmp/a.png", "/tmp/b.png"])
    }

    /// The grammar requires the path to start right at `/` with no leading whitespace before the
    /// first real character — a line that merely mentions the marker text mid-sentence, or one
    /// whose path is not absolute, must not match.
    func testALineThatIsNotAWellFormedMarkerIsIgnored() {
        XCTAssertEqual(MessageRouting.extractFilePaths("I sent a pai-file: earlier"), [])
        XCTAssertEqual(MessageRouting.extractFilePaths("pai-file: relative/path.png"), [])
        XCTAssertEqual(MessageRouting.extractFilePaths("pai-file: "), [])
    }

    func testNoMarkerAtAllReturnsAnEmptyList() {
        XCTAssertEqual(MessageRouting.extractFilePaths("just an ordinary reply"), [])
    }

    // MARK: - Expand keys

    func testToolExpandKeyFamiliesFollowTheSameOrderAsIconSelection() {
        XCTAssertEqual(MessageRouting.toolExpandKey(name: "Bash", isResult: false), "bash_call")
        XCTAssertEqual(MessageRouting.toolExpandKey(name: "MultiEdit", isResult: true), "edit_result")
        XCTAssertEqual(MessageRouting.toolExpandKey(name: "Task", isResult: false), "agent_call")
        XCTAssertEqual(MessageRouting.toolExpandKey(name: "mcp__engram__search", isResult: false), "mcp_call")
        XCTAssertEqual(MessageRouting.toolExpandKey(name: "SomeFutureTool", isResult: true), "other_result")
    }

    /// The one place JS truthiness could silently diverge from a plain `nil` check: an empty
    /// string subtype is falsy in the original and must fall to `system_other`, not `"system_"`.
    func testSystemExpandKeyTreatsAnEmptyStringSubtypeAsAbsent() {
        XCTAssertEqual(MessageRouting.systemExpandKey(subtype: ""), "system_other")
        XCTAssertEqual(MessageRouting.systemExpandKey(subtype: nil), "system_other")
        XCTAssertEqual(MessageRouting.systemExpandKey(subtype: "hook"), "system_hook")
    }
}
