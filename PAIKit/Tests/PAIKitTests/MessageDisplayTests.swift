import XCTest

@testable import PAIKit

/// These cover the places where a faithful port is easy to get subtly wrong, and where being
/// wrong is invisible: JavaScript truthiness, a regex backreference expressed as a scan, and
/// Foundation defaults that differ from `JSON.stringify`.
///
/// Assertions that a known tool name produces a known string are mostly absent — that restates
/// the switch next to the switch.
final class MessageDisplayTests: XCTestCase {

    private func call(_ name: String, _ input: [String: PaiJSONValue]) -> ToolCall {
        ToolCall(id: "t1", name: name, input: input)
    }

    // MARK: - The JSON fallback

    /// Foundation escapes forward slashes and `JSON.stringify` does not. Tool inputs are mostly
    /// file paths, so losing this turns every path in every unrecognised tool card into
    /// `\/Users\/…` — wrong on screen, and unsearchable, while still being valid JSON.
    func testJsonFallbackDoesNotEscapeSlashes() {
        let spec = MessageDisplay.spec(for: call("SomeUnknownTool", ["path": .string("/Users/frederik/x.swift")]))

        guard case .json(let text) = spec else {
            return XCTFail("expected the JSON fallback, got \(spec)")
        }
        XCTAssertTrue(text.contains("/Users/frederik/x.swift"), "slashes were escaped: \(text)")
    }

    /// The per-tool branches are guarded on the field being present *and* a string. A tool whose
    /// input does not match its usual shape has to fall through to JSON rather than render a
    /// card with an empty body — the failure otherwise looks like a tool that did nothing.
    func testKnownToolWithUnexpectedInputFallsBackToJson() {
        guard case .json = MessageDisplay.spec(for: call("Bash", ["command": .number(3)])) else {
            return XCTFail("a Bash call with a non-string command should not render as a command")
        }
        guard case .bash = MessageDisplay.spec(for: call("Bash", ["command": .string("ls")])) else {
            return XCTFail("a well-formed Bash call stopped rendering as one, so the case above proves nothing")
        }
    }

    /// Read's offset and limit arrive as JSON numbers, which are `Double` here. Interpolating one
    /// directly yields "from line 141.0".
    func testReadLineNumbersRenderAsIntegers() {
        let spec = MessageDisplay.spec(for: call("Read", ["file_path": .string("/a/b.txt"), "offset": .number(141)]))

        guard case .inline(let text) = spec else {
            return XCTFail("expected an inline spec, got \(spec)")
        }
        XCTAssertEqual(text, "/a/b.txt from line 141")
    }

    // MARK: - Line-number stripping

    /// The scan replaces a regex, so the risk is that it strips more than the prefix. A `→` in
    /// ordinary content, and a digits-less line, both have to survive untouched.
    func testStripLineNumbersTakesOnlyRealPrefixes() {
        let source = """
               141→let x = 1
            no prefix here
            a → b
            142→  indented body
            """

        XCTAssertEqual(
            MessageDisplay.stripLineNumbers(source),
            "let x = 1\nno prefix here\na → b\n  indented body"
        )
    }

    /// Stripping is routed by tool name. Applying it to everything would eat content from any
    /// result that happens to contain the arrow; applying it to nothing would leave Read output
    /// unreadable.
    func testLineNumberStrippingIsRoutedByToolName() {
        let result = ToolResult(toolUseId: "t1", toolName: "Read", content: "  1→body", isError: false)

        XCTAssertEqual(MessageDisplay.toolResultDisplayText(result, toolName: "Read"), "body")
        XCTAssertEqual(
            MessageDisplay.toolResultDisplayText(result, toolName: "Grep"),
            "  1→body",
            "line numbers were stripped for a tool that does not emit them"
        )
    }

    // MARK: - ANSI

    /// Escape sequences must not survive into displayed text, because search is built from
    /// displayed text and would count matches the reader cannot see. The second half guards the
    /// opposite error: a scan that consumes past the sequence and eats real output.
    func testAnsiStrippingRemovesOnlyTheEscapeSequence() {
        XCTAssertEqual(Ansi.strip("\u{1b}[31mred\u{1b}[0m tail"), "red tail")
        XCTAssertEqual(Ansi.strip("no escapes here"), "no escapes here")
    }

    /// Only bash output is treated as ANSI-bearing, and only when it actually contains an escape.
    func testAnsiIsStrippedForBashOutputOnly() {
        let coloured = ToolResult(toolUseId: "t1", toolName: "Bash", content: "\u{1b}[32mok", isError: false)

        XCTAssertEqual(MessageDisplay.toolResultDisplayText(coloured, toolName: "Bash"), "ok")
        XCTAssertEqual(
            MessageDisplay.toolResultDisplayText(coloured, toolName: "Read"),
            "\u{1b}[32mok",
            "a non-bash result was ANSI-stripped"
        )
    }

    // MARK: - JavaScript semantics that do not carry over

    /// `content ? … : 'System'` treats an empty string as falsy. A direct port checks only for
    /// nil and gives such a row a blank label instead of "System".
    func testEmptySystemContentStillGetsALabel() {
        XCTAssertEqual(MessageDisplay.systemLabel(subtype: nil, content: ""), "System")
        XCTAssertEqual(MessageDisplay.systemLabel(subtype: nil, content: nil), "System")
        XCTAssertEqual(MessageDisplay.systemLabel(subtype: nil, content: "something"), "something")
    }

    /// The original closes on a backreference to its own opening tag. Expressed as a scan, the
    /// easy mistake is to accept any closing tag — which would silently mislabel the card.
    func testLegacyLocalCommandTagRequiresMatchingTags() {
        let matched = MessageDisplay.legacyLocalCommandTag("<local-command-stdout>out</local-command-stdout>")
        XCTAssertEqual(matched?.kind, "stdout")
        XCTAssertEqual(matched?.inner, "out")

        XCTAssertNil(
            MessageDisplay.legacyLocalCommandTag("<local-command-stdout>out</local-command-stderr>"),
            "a mismatched closing tag was accepted"
        )
        XCTAssertNil(MessageDisplay.legacyLocalCommandTag("just text"))
    }

    // MARK: - Labels

    /// An MCP tool name carries its server, and the separator differs between the two halves —
    /// `server: tool.with.dots`. Joining the tail with the wrong separator is invisible until an
    /// MCP call appears in a transcript.
    func testMcpToolNamesSplitIntoServerAndPath() {
        XCTAssertEqual(MessageDisplay.formatToolName("mcp__engram__search_memory"), "engram: search_memory")
        XCTAssertEqual(MessageDisplay.formatToolName("mcp__a__b__c"), "a: b.c")
        XCTAssertEqual(MessageDisplay.formatToolName("Bash"), "Bash")
        XCTAssertEqual(MessageDisplay.formatToolName("mcp__nosuffix"), "mcp__nosuffix")
    }

    /// A result whose call never arrived is labelled as a result; one that has its call is not.
    func testOrphanedResultIsLabelledAsSuch() {
        let result = ToolResult(toolUseId: "t1", toolName: "Bash", content: "x", isError: false)

        XCTAssertEqual(MessageDisplay.toolCardLabel(call: nil, result: result), "Bash Result")
        XCTAssertEqual(MessageDisplay.toolCardLabel(call: call("Bash", [:]), result: result), "Bash")
    }

    /// Both halves of a labelled body, including the case where there is no separator at all —
    /// the label must then be the whole content, not the empty string.
    func testSplitLabeledContentHandlesAMissingSeparator() {
        let split = MessageDisplay.splitLabeledContent("name\n\nline one\n\nline two")
        XCTAssertEqual(split.label, "name")
        XCTAssertEqual(split.body, "line one\n\nline two", "the split consumed more than the first separator")

        XCTAssertEqual(MessageDisplay.splitLabeledContent("bare").label, "bare")
        XCTAssertEqual(MessageDisplay.splitLabeledContent("bare").body, "")
    }
}
