import XCTest

@testable import PAIKit

/// These target the ways the block model can break without anyone noticing: text quietly
/// rewritten, a row shape a renderer will index past the end of, structure flattened by a
/// refactor, and content dropped by a node nobody thought about.
///
/// Straightforward shape assertions — that `# x` yields a heading — are mostly absent. They
/// restate the parser next to the parser and would only ever break on purpose.
///
/// Nothing here has been watched failing, because there is no Swift toolchain outside CI. Where
/// it mattered most, the test compensates by asserting a *contrast* within one run: if the
/// behaviour under test were not happening, both halves could not hold at once.
final class MarkdownParserTests: XCTestCase {

    // MARK: - Text must survive the parse unchanged

    /// The highest-value test in this file. swift-markdown enables cmark's smart punctuation by
    /// default, which rewrites `--` to an en dash and curls quotes. In a transcript of shell
    /// commands that corrupts the exact characters a reader is checking, and it looks like the
    /// model typed it that way.
    ///
    /// The second half is what makes this a real test rather than a restatement: parsing the
    /// same source with the option cleared shows the mangling is real and that the configured
    /// options are the only thing preventing it.
    func testSmartPunctuationIsDisabled() {
        let source = #"Run `git push --force` and pass "now" -- carefully."#

        let text = plainText(of: MarkdownParser.parse(source))
        XCTAssertTrue(text.contains("--force"), "en dash substitution reached a command line: \(text)")
        XCTAssertTrue(text.contains("\"now\""), "quotes were curled: \(text)")

        let unguarded = plainText(of: MarkdownParser.parse(source, options: []))
        XCTAssertFalse(
            unguarded.contains(" -- "),
            "smart punctuation did not fire without the option, so this test proves nothing"
        )
    }

    /// Code is the one place where every character is content. A trailing blank line would also
    /// add height to every code block in the transcript.
    func testCodeBlockPreservesItsContentExactly() {
        let source = """
            ```swift
            let quoted = "a -- b"

            print(quoted)
            ```
            """

        guard case .codeBlock(let language, let code)? = MarkdownParser.parse(source).first else {
            return XCTFail("expected a code block, got \(MarkdownParser.parse(source))")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "let quoted = \"a -- b\"\n\nprint(quoted)")
    }

    /// Raw HTML reaches no component in the web client and vanishes. This client shows the
    /// source instead, and that difference is deliberate — a record that silently drops a line
    /// because it began with `<` is worse than an ugly one.
    func testHtmlBlockKeepsItsSourceRatherThanVanishing() {
        guard case .htmlBlock(let raw)? = MarkdownParser.parse("<details><summary>x</summary>").first else {
            return XCTFail("HTML block was dropped")
        }
        XCTAssertTrue(raw.contains("<summary>"))
    }

    /// A catch-all for the failure this model is most exposed to: a case added, reordered or
    /// rewritten later that silently contributes nothing. Each marker word appears in exactly
    /// one block kind, so a dropped kind is a missing word.
    func testNoBlockKindDropsItsContent() {
        let source = """
            # headingword

            paragraphword

            > quoteword

            - listword
            - [x] taskword

            ```
            codeword
            ```

            | headerword |
            | --- |
            | cellword |

            ---

            <p>htmlword</p>
            """

        let blocks = MarkdownParser.parse(source)
        XCTAssertGreaterThanOrEqual(blocks.count, 8, "the fixture did not produce every block kind: \(blocks)")

        let text = plainText(of: blocks)
        for word in [
            "headingword", "paragraphword", "quoteword", "listword",
            "taskword", "codeword", "headerword", "cellword", "htmlword",
        ] {
            XCTAssertTrue(text.contains(word), "\(word) was lost")
        }
    }

    // MARK: - Shapes a renderer indexes into

    /// A measuring pass walks a table as a grid. A short row there is an out-of-bounds crash
    /// rather than a visible mistake, so every row is padded or truncated to one width.
    func testTableIsAlwaysRectangular() {
        let source = """
            | a | b | c |
            | :- | :-: | -: |
            | 1 | 2 |
            | 1 | 2 | 3 | 4 |
            """

        guard case .table(let table)? = MarkdownParser.parse(source).first else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(table.columnCount, 3)
        XCTAssertEqual(table.alignments, [.left, .center, .right])
        for row in table.rows {
            XCTAssertEqual(row.count, table.columnCount, "ragged row reached the model: \(row)")
        }
    }

    /// Both break kinds are one `SoftBreak`/`LineBreak` apart in the parse tree and trivially
    /// confused. Treating a soft break as a newline would change the measured height of most
    /// paragraphs in the transcript; the two assertions together pin which is which.
    func testSoftBreakIsASpaceAndHardBreakIsANewline() {
        XCTAssertEqual(plainText(of: MarkdownParser.parse("one\ntwo")), "one two")
        XCTAssertEqual(plainText(of: MarkdownParser.parse("one  \ntwo")), "one\ntwo")
    }

    // MARK: - Structure a refactor could flatten

    func testNestingSurvivesToTheInnermostBlock() {
        let source = """
            > - item text
            >
            >   ```sh
            >   echo hi
            >   ```
            """

        guard case .blockQuote(let quoted)? = MarkdownParser.parse(source).first,
            case .list(let list)? = quoted.first,
            let item = list.items.first
        else {
            return XCTFail("quote > list > item did not survive: \(MarkdownParser.parse(source))")
        }
        XCTAssertTrue(
            item.blocks.contains { block in
                if case .codeBlock(let language, let code) = block { return language == "sh" && code == "echo hi" }
                return false
            },
            "the code block inside the list item was lost: \(item.blocks)"
        )
    }

    /// Styling is applied while descending the tree, so an inner node inheriting only part of
    /// what encloses it is an easy regression — and one that reads as a font bug rather than a
    /// parser bug. The link destination has to survive the same descent.
    func testStylesAndLinkComposeThroughNesting() {
        let runs = MarkdownParser.parse("[**bold `code`**](https://example.com)").firstParagraphRuns

        guard let code = runs.first(where: { $0.text == "code" }) else {
            return XCTFail("no run carried the inline code: \(runs)")
        }
        XCTAssertTrue(code.style.contains(.bold), "the enclosing emphasis was lost")
        XCTAssertTrue(code.style.contains(.code))
        XCTAssertEqual(code.destination, "https://example.com", "the enclosing link was lost")
    }

    /// An image has no synchronously knowable height, so it is shown as a link. The risk is that
    /// a later change treats "not rendered as an image" as "not rendered", and the reference
    /// disappears from the record.
    func testImageIsKeptAsALinkRatherThanDropped() {
        let runs = MarkdownParser.parse("![a diagram](https://example.com/d.png)").firstParagraphRuns
        XCTAssertEqual(runs.map(\.text), ["a diagram"])
        XCTAssertEqual(runs.first?.destination, "https://example.com/d.png")
    }

    // MARK: - List details carried from the source

    func testTaskListStateAndOrdinalStartAreCarried() {
        guard case .list(let tasks)? = MarkdownParser.parse("- [x] done\n- [ ] todo").first else {
            return XCTFail("expected a list")
        }
        XCTAssertEqual(tasks.items.map(\.checkbox), [.checked, .unchecked])

        // A numbered list that does not start at 1 renders wrongly if the ordinal is assumed.
        guard case .list(let numbered)? = MarkdownParser.parse("5. five\n6. six").first else {
            return XCTFail("expected an ordered list")
        }
        XCTAssertEqual(numbered.marker, .ordered(start: 5))
        XCTAssertNil(numbered.items.first?.checkbox, "an ordinary item was given a checkbox")
    }

    // MARK: - Helpers

    /// Flattens a block tree to its visible text, so a test can assert that content survived
    /// without asserting the shape it survived in.
    private func plainText(of blocks: [MarkdownBlock]) -> String {
        blocks.map { block in
            switch block {
            case .paragraph(let text), .heading(_, let text):
                return text.plainText
            case .codeBlock(_, let code):
                return code
            case .htmlBlock(let raw):
                return raw
            case .thematicBreak:
                return ""
            case .blockQuote(let inner):
                return plainText(of: inner)
            case .list(let list):
                return list.items.map { plainText(of: $0.blocks) }.joined(separator: "\n")
            case .table(let table):
                return ([table.header] + table.rows)
                    .map { $0.map(\.plainText).joined(separator: " ") }
                    .joined(separator: "\n")
            }
        }
        .joined(separator: "\n")
    }
}

extension [MarkdownBlock] {
    /// The runs of the first paragraph, or nothing — keeps the inline tests to one line of setup.
    fileprivate var firstParagraphRuns: [InlineRun] {
        for block in self {
            if case .paragraph(let text) = block { return text.runs }
        }
        return []
    }
}
