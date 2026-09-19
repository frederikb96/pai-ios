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

    /// A string value is written as-is rather than JSON-encoded. Tool inputs are mostly file
    /// paths, so encoding one turns every path in every unrecognised tool card into `\/Users\/…`
    /// — wrong on screen, and unsearchable, while still being valid JSON.
    func testKeyValueFallbackDoesNotEscapeSlashes() {
        let spec = MessageDisplay.spec(for: call("SomeUnknownTool", ["path": .string("/Users/frederik/x.swift")]))

        guard case .keyValue(let lines) = spec else {
            return XCTFail("expected the key/value fallback, got \(spec)")
        }
        XCTAssertEqual(lines, ["path: /Users/frederik/x.swift"])
    }

    /// The per-tool branches are guarded on the field being present *and* a string. A tool whose
    /// input does not match its usual shape has to fall through to the key/value shape rather than render a
    /// card with an empty body — the failure otherwise looks like a tool that did nothing.
    func testKnownToolWithUnexpectedInputFallsBackToKeyValue() {
        guard case .keyValue = MessageDisplay.spec(for: call("Bash", ["command": .number(3)])) else {
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

    // MARK: - Edit display text

    /// The actual regression: a multi-line old/new pair used to glue one `-`/`+` onto the whole
    /// block, so only the first line of each side ever carried a marker and every continuation
    /// line rendered as plain text. Every line must carry its own marker now.
    func testEditDisplayTextMarksEveryLineOfAMultiLineChange() {
        let text = MessageDisplay.displayText(
            of: .edit(filePath: "/a.swift", oldString: "one\ntwo", newString: "three\nfour"))

        XCTAssertEqual(text, "- one\n- two\n+ three\n+ four")
    }

    /// A line unchanged between old and new must appear once, not duplicated under both `-` and
    /// `+` — the whole-block gluing did not diff at all, so this line would previously have shown
    /// up twice.
    func testEditDisplayTextShowsAnUnchangedLineOnceAsContext() {
        let text = MessageDisplay.displayText(
            of: .edit(filePath: "/a.swift", oldString: "keep\nold", newString: "keep\nnew"))

        XCTAssertEqual(text, "keep\n- old\n+ new")
    }

    /// The path is the card's header, never part of its body — which is the point of lifting it
    /// out: a diff scrolls sideways, and the first thing a reader needs is the one thing that
    /// scrolls out of reach.
    func testTheEditedPathIsTheHeaderAndNotInTheBody() {
        let spec = MessageDisplay.ToolCallSpec.edit(filePath: "~/a.swift", oldString: "old", newString: "new")

        XCTAssertEqual(MessageDisplay.headerPath(of: spec), "~/a.swift")
        XCTAssertFalse(MessageDisplay.displayText(of: spec).contains("a.swift"))
    }

    /// An edit with nothing to diff has an empty body — the header alone says what happened.
    func testEditDisplayTextWithNeitherStringIsEmpty() {
        let text = MessageDisplay.displayText(of: .edit(filePath: "/a.swift", oldString: nil, newString: nil))

        XCTAssertEqual(text, "")
    }

    /// A write's content is its body and its path is its header, the same split an edit gets.
    func testAWritesPathIsItsHeaderAndItsContentIsItsBody() {
        let spec = MessageDisplay.ToolCallSpec.write(filePath: "~/b.txt", content: "hello")

        XCTAssertEqual(MessageDisplay.headerPath(of: spec), "~/b.txt")
        XCTAssertEqual(MessageDisplay.displayText(of: spec), "hello")
    }

    // MARK: - Home abbreviation

    /// Both shapes a Unix home takes, and only at the front — a `/home/` deeper in a path is a
    /// directory somebody named, not a home.
    func testHomeIsAbbreviatedOnlyAtTheStartOfAPath() {
        XCTAssertEqual(MessageDisplay.abbreviatingHome("/home/frederik/Programming/x"), "~/Programming/x")
        XCTAssertEqual(MessageDisplay.abbreviatingHome("/Users/frederik/Code/y"), "~/Code/y")
        XCTAssertEqual(MessageDisplay.abbreviatingHome("/home/frederik"), "~")
        XCTAssertEqual(MessageDisplay.abbreviatingHome("/srv/home/frederik/x"), "/srv/home/frederik/x")
        XCTAssertEqual(MessageDisplay.abbreviatingHome("/etc/passwd"), "/etc/passwd")
    }

    /// 🚨 The model keeps the raw path, because the model is what the client search index counts
    /// occurrences in and the server matches against the raw stored content. A shortened path in
    /// here would make the two disagree — a row highlighted while the counter reads zero.
    /// Shortening belongs on the card header, which is outside the index.
    func testTheModelKeepsTheRawPathSoSearchStillAgreesWithTheStore() {
        let read = MessageDisplay.spec(for: call("Read", ["file_path": .string("/home/frederik/a.swift")]))
        XCTAssertEqual(MessageDisplay.displayText(of: read), "/home/frederik/a.swift")

        let grep = MessageDisplay.spec(
            for: call("Grep", ["pattern": .string("x"), "path": .string("/home/frederik/src")]))
        XCTAssertEqual(MessageDisplay.displayText(of: grep), "/x/ in /home/frederik/src")

        let edit = MessageDisplay.spec(for: call("Edit", ["file_path": .string("/home/frederik/a.swift")]))
        XCTAssertEqual(MessageDisplay.headerPath(of: edit), "/home/frederik/a.swift")
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

    /// ANSI is stripped from every tool, not only from Bash: colour in the transcript means
    /// state, so output that paints itself competes with the one signal worth finding while
    /// scrolling — and a preview slices this string, which cannot be done safely on text carrying
    /// escapes, since a cut landing mid-sequence leaks the escape onto the screen.
    func testAnsiIsStrippedWhicheverToolProducedIt() {
        let coloured = ToolResult(toolUseId: "t1", toolName: "Bash", content: "\u{1b}[32mok", isError: false)

        XCTAssertEqual(MessageDisplay.toolResultDisplayText(coloured, toolName: "Bash"), "ok")
        XCTAssertEqual(MessageDisplay.toolResultDisplayText(coloured, toolName: "Read"), "ok")
        XCTAssertEqual(MessageDisplay.toolResultDisplayText(coloured, toolName: nil), "ok")
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

    /// The label is the tool's own name whichever side it was read from — a result no longer says
    /// "Result", because its glyph and its place under the call are what say so, and repeating the
    /// word cost a whole line on every result in the transcript.
    func testToolCardLabelIsTheToolName() {
        let result = ToolResult(toolUseId: "t1", toolName: "Bash", content: "x", isError: false)

        XCTAssertEqual(MessageDisplay.toolCardLabel(call: nil, result: result), "Bash")
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

    // MARK: - parseNotifyReply

    /// Every fixture below is real output of `backend/src/pai_cloud/mcp_serializer.py`'s
    /// `serialize_response`, captured directly rather than hand-typed — the same fixtures the
    /// web's `parseNotifyReply` tests use, since the two are meant to agree on when to
    /// special-case a reply.
    func testParseNotifyReplyExtractsPlainSingleLineScalars() {
        let content =
            "status: ok\nsent: true\nnotification_id: id\nmarker: pai-notify:x\n"
            + "title: Deploy finished\nbody: The release is live.\n"
        let reply = MessageDisplay.parseNotifyReply(content)
        XCTAssertEqual(reply?.title, "Deploy finished")
        XCTAssertEqual(reply?.body, "The release is live.")
    }

    /// PyYAML only switches to its quoted form when a plain scalar cannot represent the value at
    /// all — a value merely containing an apostrophe (not at the very start) stays plain. The
    /// boundary this checks is "quoted" meaning "starts with a quote", not "contains one".
    func testParseNotifyReplyDoesNotMistakeAMidStringApostropheForTheQuotedForm() {
        let content = "status: ok\ntitle: It's fine\nbody: ok\n"
        let reply = MessageDisplay.parseNotifyReply(content)
        XCTAssertEqual(reply?.title, "It's fine")
        XCTAssertEqual(reply?.body, "ok")
    }

    /// An inline `: ` forces PyYAML's single-quoted style. Captured verbatim from a real
    /// notification title.
    func testParseNotifyReplyParsesASingleQuotedScalarWithAnInlineColon() {
        let content =
            "status: ok\nsent: true\nnotification_id: id\nmarker: pai-notify:x\n"
            + "title: 'talos ❓ Cluster health: 3 NVMe disks wearing out'\nbody: x\n"
        let reply = MessageDisplay.parseNotifyReply(content)
        XCTAssertEqual(reply?.title, "talos ❓ Cluster health: 3 NVMe disks wearing out")
        XCTAssertEqual(reply?.body, "x")
    }

    /// PyYAML doubles an embedded apostrophe (`''`) inside a single-quoted scalar. Captured
    /// verbatim from a real notification body.
    func testParseNotifyReplyUnescapesADoubledApostropheInASingleQuotedScalar() {
        let content =
            "status: ok\nsent: true\nnotification_id: id\nmarker: pai-notify:x\n"
            + "title: x\n"
            + "body: 'D7: I''ll merge PR #862 after the Immich rebuild, before node2, unless you say no."
            + " Mayastor drops a replica away >10 min and re-copies it in full; for node2''s HDD replicas"
            + " that''s a day each. 30 min covers a Robot power cycle.'\n"
        let reply = MessageDisplay.parseNotifyReply(content)
        XCTAssertEqual(
            reply?.body,
            "D7: I'll merge PR #862 after the Immich rebuild, before node2, unless you say no."
                + " Mayastor drops a replica away >10 min and re-copies it in full; for node2's HDD replicas"
                + " that's a day each. 30 min covers a Robot power cycle.")
    }

    /// A control character (a literal tab, here) forces PyYAML's double-quoted style, escaped
    /// with its own backslash sequences.
    func testParseNotifyReplyUnescapesADoubleQuotedScalar() {
        let content =
            "status: ok\nsent: true\nnotification_id: id\nmarker: pai-notify:x\n"
            + "title: x\nbody: \"value\\twith\\ttab\"\n"
        let reply = MessageDisplay.parseNotifyReply(content)
        XCTAssertEqual(reply?.body, "value\twith\ttab")
    }

    /// A plain scalar long enough to cross PyYAML's output width folds onto an indented
    /// continuation line with no quoting at all; a lone fold rejoins with a single space.
    func testParseNotifyReplyRejoinsAWidthWrappedPlainContinuationLine() {
        let words = (0..<200).map { "word\($0)" }.joined(separator: " ")
        let firstLine = (0...138).map { "word\($0)" }.joined(separator: " ")
        let continuation = (139...199).map { "word\($0)" }.joined(separator: " ")
        let content = "status: ok\ntitle: x\nbody: \(firstLine)\n  \(continuation)\n"
        let reply = MessageDisplay.parseNotifyReply(content)
        XCTAssertEqual(reply?.body, words)
    }

    /// The same width-wrap fold inside a single-quoted scalar, where an inline `: ` also forced
    /// the quoted style.
    func testParseNotifyReplyRejoinsAWidthWrappedSingleQuotedContinuationLine() {
        let words = (0..<200).map { "word\($0)" }.joined(separator: " ")
        let firstLine = (0...137).map { "word\($0)" }.joined(separator: " ")
        let continuation = (138...199).map { "word\($0)" }.joined(separator: " ")
        let content = "status: ok\ntitle: x\nbody: 'note: \(firstLine)\n  \(continuation)'\n"
        let reply = MessageDisplay.parseNotifyReply(content)
        XCTAssertEqual(reply?.body, "note: " + words)
    }

    /// Two consecutive line breaks inside a quoted scalar are PyYAML's encoding of a literal
    /// embedded newline, not a width-wrap fold — reversing that correctly means re-implementing
    /// YAML's line-folding rules, which this deliberately does not attempt.
    func testParseNotifyReplyReturnsNilWhenBodyNeededTheQuotedFormForAnEmbeddedLineBreak() {
        let content =
            "status: ok\nsent: true\nnotification_id: id\nmarker: pai-notify:x\n"
            + "title: Deploy finished\nbody: 'The release is live.\n\n  Check it out.'\n"
        XCTAssertNil(MessageDisplay.parseNotifyReply(content))
    }

    func testParseNotifyReplyReturnsNilForAReplyCarryingNeitherField() {
        XCTAssertNil(MessageDisplay.parseNotifyReply("status: ok\nsent: false\nreason: rate_limited\n"))
    }
}
