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

        let text = MarkdownParser.parse(source).plainText
        XCTAssertTrue(text.contains("--force"), "en dash substitution reached a command line: \(text)")
        XCTAssertTrue(text.contains("\"now\""), "quotes were curled: \(text)")

        let unguarded = MarkdownParser.parse(source, options: []).plainText
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

    /// An HTML comment is the one raw-HTML shape that is never meant to be seen, on any HTML
    /// consumer. Dropping the comment must not touch the paragraph it wraps: that is the
    /// contrast that shows the block was recognised and removed on purpose, not merely lost
    /// along with everything around it.
    func testHTMLCommentBlockIsDroppedButWhatItWrapsSurvives() {
        let source = """
            <!-- marker -->
            keep-this-text
            <!-- marker -->
            """
        let blocks = MarkdownParser.parse(source)
        XCTAssertFalse(blocks.contains { if case .htmlBlock = $0 { return true } else { return false } },
                        "the comment block rendered as visible source: \(blocks)")
        XCTAssertTrue(blocks.plainText.contains("keep-this-text"), "the wrapped paragraph was lost too: \(blocks)")
    }

    /// The scheduler's standing-instructions marker is three zero-width Unicode characters
    /// (U+200B, U+2060, U+200C) rather than markup — invisible by construction, not by any
    /// renderer's choice, so unlike the HTML-comment case above it must reach `plainText`
    /// completely unchanged for the backend's own substring detection (`_standing_instructions_
    /// need_resend`) to keep working. A parser upgrade that started normalising or trimming
    /// zero-width format characters as whitespace would silently make every fire resend the
    /// instructions, with nothing in this app's own UI ever showing a symptom.
    func testZeroWidthSchedulerMarkerSurvivesParsingIntact() {
        let marker = "\u{200B}\u{2060}\u{200C}"
        let source = "\(marker)\ninstructions\n\(marker)\n\ntask prompt"

        let text = MarkdownParser.parse(source).plainText
        XCTAssertEqual(text.components(separatedBy: marker).count - 1, 2, "expected the marker twice, unchanged: \(text.unicodeScalars.map(\.value))")
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

        let text = blocks.plainText
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
        XCTAssertEqual(MarkdownParser.parse("one\ntwo").plainText, "one two")
        XCTAssertEqual(MarkdownParser.parse("one  \ntwo").plainText, "one\ntwo")
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

    // MARK: - Bare URLs

    /// The cmark-gfm "autolink" extension is not attached (`MarkdownParser`'s own doc comment
    /// explains why), so a bare URL reaching a real link destination proves the fallback pass is
    /// what did it, not cmark itself.
    func testBareUrlBecomesALink() {
        let runs = MarkdownParser.parse("See https://example.com/path for details.").firstParagraphRuns
        guard let link = runs.first(where: { $0.destination != nil }) else {
            return XCTFail("no run carried a link destination: \(runs)")
        }
        XCTAssertEqual(link.text, "https://example.com/path")
        XCTAssertEqual(link.destination, "https://example.com/path")
        XCTAssertEqual(runs.map(\.text).joined(), "See https://example.com/path for details.")
    }

    /// Sentence punctuation immediately after a URL almost never belongs to it — the link must
    /// stop before the period, not swallow it.
    func testTrailingSentencePunctuationIsNotPartOfTheLink() {
        let runs = MarkdownParser.parse("Read https://example.com/x.").firstParagraphRuns
        guard let link = runs.first(where: { $0.destination != nil }) else {
            return XCTFail("no run carried a link destination: \(runs)")
        }
        XCTAssertEqual(link.text, "https://example.com/x")
        XCTAssertFalse(link.text.hasSuffix("."), "the trailing period was swallowed into the link")
    }

    /// GFM's "www autolink": a bare domain with no scheme still becomes a link, with an implicit
    /// `http://` prefix on the destination — but the visible label stays exactly what was typed,
    /// not the synthesized destination.
    func testBareWwwDomainBecomesALinkWithAnImplicitScheme() {
        let runs = MarkdownParser.parse("See www.example.com for details.").firstParagraphRuns
        guard let link = runs.first(where: { $0.destination != nil }) else {
            return XCTFail("no run carried a link destination: \(runs)")
        }
        XCTAssertEqual(link.text, "www.example.com")
        XCTAssertEqual(link.destination, "http://www.example.com")
    }

    /// A URL whose path contains a genuinely balanced pair of parentheses — the classic case is a
    /// Wikipedia disambiguation link — must keep its closing paren as part of the link rather than
    /// treating it as prose punctuation wrapping the URL.
    func testBalancedParenthesesInsideTheUrlAreKept() {
        let runs = MarkdownParser.parse("See https://en.wikipedia.org/wiki/Foo_(bar) for details.").firstParagraphRuns
        guard let link = runs.first(where: { $0.destination != nil }) else {
            return XCTFail("no run carried a link destination: \(runs)")
        }
        XCTAssertEqual(link.text, "https://en.wikipedia.org/wiki/Foo_(bar)")
    }

    /// The mirror case: a URL wrapped in prose parentheses, with nothing balanced inside it, must
    /// lose the outer closing paren — it was never part of the link.
    func testUnbalancedTrailingParenthesisIsExcludedFromTheLink() {
        let runs = MarkdownParser.parse("(see https://example.com/x)").firstParagraphRuns
        guard let link = runs.first(where: { $0.destination != nil }) else {
            return XCTFail("no run carried a link destination: \(runs)")
        }
        XCTAssertEqual(link.text, "https://example.com/x")
        XCTAssertEqual(
            runs.map(\.text).joined(), "(see https://example.com/x)", "the closing paren must survive as plain text")
    }

    /// A URL already inside real markdown link syntax must not be re-split — the destination
    /// composed through `[text](url)` is what should survive, unchanged.
    func testUrlInsideAMarkdownLinkIsNotReautolinked() {
        let runs = MarkdownParser.parse("[https://example.com](https://example.com/actual)").firstParagraphRuns
        XCTAssertEqual(runs.map(\.text), ["https://example.com"])
        XCTAssertEqual(runs.first?.destination, "https://example.com/actual")
    }

    /// A URL inside an inline code span is source, not prose — it must stay exactly as written
    /// and never become tappable.
    func testUrlInsideInlineCodeIsLeftAlone() {
        let runs = MarkdownParser.parse("Run `curl https://example.com/x`").firstParagraphRuns
        guard let code = runs.first(where: { $0.style.contains(.code) }) else {
            return XCTFail("no code run: \(runs)")
        }
        XCTAssertEqual(code.text, "curl https://example.com/x")
        XCTAssertNil(code.destination, "a code span became tappable")
    }

    // MARK: - Bare email addresses

    /// GFM's "extended email autolink" — matched on the web side too — turns a bare address into
    /// a `mailto:` link with no surrounding markdown syntax needed.
    func testBareEmailBecomesAMailtoLink() {
        let runs = MarkdownParser.parse("Reach me at fberg@posteo.de please.").firstParagraphRuns
        guard let link = runs.first(where: { $0.destination != nil }) else {
            return XCTFail("no run carried a link destination: \(runs)")
        }
        XCTAssertEqual(link.text, "fberg@posteo.de")
        XCTAssertEqual(link.destination, "mailto:fberg@posteo.de")
    }

    /// A domain with no dot at all is not a valid autolink target — "user@localhost" stays plain
    /// text on the web too.
    func testEmailWithNoDotInTheDomainStaysPlainText() {
        let runs = MarkdownParser.parse("ping user@localhost now").firstParagraphRuns
        XCTAssertNil(runs.first(where: { $0.destination != nil }))
        XCTAssertEqual(runs.map(\.text).joined(), "ping user@localhost now")
    }

    /// Sentence punctuation right after an address must stay out of the link, the same rule the
    /// URL branch already enforces.
    func testTrailingSentencePunctuationIsNotPartOfTheEmailLink() {
        let runs = MarkdownParser.parse("Mail fberg@posteo.de.").firstParagraphRuns
        guard let link = runs.first(where: { $0.destination != nil }) else {
            return XCTFail("no run carried a link destination: \(runs)")
        }
        XCTAssertEqual(link.text, "fberg@posteo.de")
        XCTAssertFalse(link.text.hasSuffix("."), "the trailing period was swallowed into the link")
    }

    /// An address inside an inline code span is source, not prose — same guarantee as a URL's.
    func testEmailInsideInlineCodeIsLeftAlone() {
        let runs = MarkdownParser.parse("Run `mail -s hi fberg@posteo.de`").firstParagraphRuns
        guard let code = runs.first(where: { $0.style.contains(.code) }) else {
            return XCTFail("no code run: \(runs)")
        }
        XCTAssertEqual(code.text, "mail -s hi fberg@posteo.de")
        XCTAssertNil(code.destination, "a code span became tappable")
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
