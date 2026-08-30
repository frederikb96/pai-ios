import XCTest

@testable import PAIKit

/// Highlighting is the whole visible difference between this editor and a plain text box, and
/// almost every way it goes wrong is silent: a marker styled as content, a range that is one
/// UTF-16 unit off, a delimiter that swallows the rest of the line looking for a partner.
final class MarkdownSourceHighlighterTests: XCTestCase {

    /// Reads a span back as the source it covers, which is what makes these assertions about
    /// what the reader sees rather than about arithmetic.
    private func styled(_ source: String, _ style: MarkdownSourceStyle) -> [String] {
        let utf16 = Array(source.utf16)
        return MarkdownSourceHighlighter.spans(for: source)
            .filter { $0.style == style }
            .map { String(decoding: utf16[$0.location..<$0.end], as: UTF16.self) }
    }

    // MARK: The invariant

    /// Every span has to be a real range of the source. An offset past the end crashes the text
    /// view rather than mis-styling something, and it only happens on input nobody wrote a test
    /// for — so this runs over the awkward cases rather than the tidy ones.
    func testEverySpanIsWithinTheSource() {
        let sources = [
            "", "#", "###### six", "####### seven", "*", "**", "***", "`", "``", "```",
            "[", "[]", "[](", "[[", "[[]]", "~~", "~", "> ", ">>>", "- ", "1.", "---",
            "**bold** and *em* and `code`", "a\n\nb", "\n\n\n", "  \t  ",
            "# ÜBERSCHRIFT mit **fett**", "emoji 🎉 **bold** 🎉", "`🎉` inline",
            "| a | b |\n|---|---|\n", "---\nid: 1\n---\nbody\n", "```\nunterminated\n",
        ]
        for source in sources {
            let count = source.utf16.count
            for span in MarkdownSourceHighlighter.spans(for: source) {
                XCTAssertGreaterThanOrEqual(span.location, 0, "negative location in \(source.debugDescription)")
                XCTAssertGreaterThan(span.length, 0, "empty span in \(source.debugDescription)")
                XCTAssertLessThanOrEqual(span.end, count, "span past the end of \(source.debugDescription)")
            }
        }
    }

    /// The trap this whole file is offset-typed to avoid. A parser reporting character or UTF-8
    /// positions agrees with UTF-16 on ASCII and diverges on the first emoji — so the bug never
    /// shows up in a test written in English, only in Freddy's actual notes.
    func testOffsetsAreUtf16NotCharacters() {
        let source = "🎉 **bold**"
        let bold = MarkdownSourceHighlighter.spans(for: source).first { $0.style == .strong }
        guard let bold else { return XCTFail("no strong span") }
        let utf16 = Array(source.utf16)
        XCTAssertEqual(String(decoding: utf16[bold.location..<bold.end], as: UTF16.self), "bold")
    }

    // MARK: Headings

    func testAHeadingSplitsIntoADimmedMarkerAndStyledText() {
        XCTAssertEqual(styled("## Title\n", .marker), ["## "])
        XCTAssertEqual(styled("## Title\n", .heading(level: 2)), ["Title"])
    }

    func testHeadingLevelIsTheNumberOfHashes() {
        XCTAssertEqual(styled("###### deep\n", .heading(level: 6)), ["deep"])
    }

    /// Seven hashes is not a heading in CommonMark, and styling it as one would make a line of
    /// hashes grow enormous as it is typed.
    func testSevenHashesIsNotAHeading() {
        XCTAssertTrue(styled("####### nope\n", .heading(level: 6)).isEmpty)
    }

    /// A tag, not a heading. Without the required space every `#todo` in the vault becomes a
    /// title-sized line.
    func testAHashWithNoSpaceIsATagNotAHeading() {
        for level in 1...6 {
            XCTAssertTrue(styled("#tag\n", .heading(level: level)).isEmpty)
        }
    }

    func testBoldInsideAHeadingIsStillBold() {
        XCTAssertEqual(styled("# a **b** c\n", .strong), ["b"])
    }

    // MARK: Inline

    func testBoldAndItalicAreDistinguished() {
        XCTAssertEqual(styled("**strong** and *em*\n", .strong), ["strong"])
        XCTAssertEqual(styled("**strong** and *em*\n", .emphasis), ["em"])
    }

    func testUnderscoresWorkTheSameAsAsterisks() {
        XCTAssertEqual(styled("__strong__ and _em_\n", .strong), ["strong"])
        XCTAssertEqual(styled("__strong__ and _em_\n", .emphasis), ["em"])
    }

    func testStrikethroughNeedsTwoTildes() {
        XCTAssertEqual(styled("~~gone~~\n", .strikethrough), ["gone"])
        XCTAssertTrue(styled("~one~\n", .strikethrough).isEmpty)
    }

    /// A code span's contents are literal. Styling markup inside one is the classic highlighter
    /// bug and it is loud — every documented example of markdown syntax renders wrong.
    func testMarkupInsideACodeSpanIsNotStyled() {
        XCTAssertEqual(styled("`**not bold**`\n", .inlineCode), ["**not bold**"])
        XCTAssertTrue(styled("`**not bold**`\n", .strong).isEmpty)
    }

    /// A code span closes on a run of the same length, so `` `a` `` inside a double-backtick
    /// span is content.
    func testACodeSpanClosesOnAMatchingRun() {
        XCTAssertEqual(styled("``a `b` c``\n", .inlineCode), ["a `b` c"])
    }

    /// The case that would corrupt a whole paragraph: an opener with no partner must style
    /// nothing rather than run to the end of the line.
    func testAnUnclosedDelimiterStylesNothing() {
        XCTAssertTrue(styled("a ** dangling and more text\n", .strong).isEmpty)
        XCTAssertTrue(styled("a ` dangling and more text\n", .inlineCode).isEmpty)
    }

    func testALinkSeparatesItsTextFromItsUrl() {
        XCTAssertEqual(styled("[label](https://x.dev)\n", .linkText), ["label"])
        XCTAssertEqual(styled("[label](https://x.dev)\n", .url), ["https://x.dev"])
    }

    /// A wikilink is how notes reference each other, so it must not be read as a plain link with
    /// a stray bracket — its target is what a tap resolves.
    func testAWikilinkIsItsOwnThing() {
        XCTAssertEqual(styled("see [[Other Note]] there\n", .wikilink), ["Other Note"])
        XCTAssertTrue(styled("see [[Other Note]] there\n", .linkText).isEmpty)
    }

    // MARK: Blocks

    func testFencesAreMarkersAndTheirContentsAreCode() {
        let source = "```swift\nlet x = 1\n```\n"
        XCTAssertEqual(styled(source, .codeBlockContent), ["let x = 1\n"])
        XCTAssertEqual(styled(source, .marker), ["```swift\n", "```\n"])
    }

    /// Inside a fence nothing is markdown. A heading line in a code sample must not grow.
    func testAHeadingInsideAFenceIsJustCode() {
        XCTAssertTrue(styled("```\n# not a heading\n```\n", .heading(level: 1)).isEmpty)
    }

    func testAListMarkerIsStyledSeparatelyFromItsItem() {
        XCTAssertEqual(styled("- item\n", .listMarker), ["- "])
        XCTAssertEqual(styled("1. item\n", .listMarker), ["1. "])
    }

    /// A checkbox belongs to the marker. Left to the inline pass it reads as an empty link.
    func testATaskCheckboxBelongsToTheMarker() {
        XCTAssertEqual(styled("- [x] done\n", .listMarker), ["- [x] "])
    }

    /// `-word` is not a list, and `1.5` is not an ordered item. Both appear constantly in prose.
    func testAMarkerNeedsATrailingSpace() {
        XCTAssertTrue(styled("-word\n", .listMarker).isEmpty)
        XCTAssertTrue(styled("1.5 metres\n", .listMarker).isEmpty)
    }

    func testABlockquoteMarkerIsDimmedAndItsTextIsQuoted() {
        XCTAssertEqual(styled("> quoted\n", .marker), ["> "])
        XCTAssertEqual(styled("> quoted\n", .quote), ["quoted"])
    }

    func testAQuotedHeadingIsStillAHeading() {
        XCTAssertEqual(styled("> # Title\n", .heading(level: 1)), ["Title"])
    }

    func testAThematicBreakIsStyledAsOne() {
        XCTAssertEqual(styled("text\n\n---\n\nmore\n", .thematicBreak), ["---"])
    }

    // MARK: Frontmatter

    /// The YAML block is styled as one unit and never parsed — anything that parsed it could
    /// rewrite Freddy's vault metadata on save.
    func testFrontmatterAtTheTopIsOneUnit() {
        XCTAssertEqual(
            styled("---\nid: 1\nsummary: x\n---\nbody\n", .frontmatter), ["---\nid: 1\nsummary: x\n---\n"])
    }

    /// A `---` in the middle of a note is a thematic break. Read as frontmatter it would grey out
    /// everything below it.
    func testAThematicBreakMidNoteIsNotFrontmatter() {
        XCTAssertTrue(styled("intro\n\n---\n\ntail\n", .frontmatter).isEmpty)
    }

    /// An unterminated opener is a thematic break followed by text, not a note that is entirely
    /// metadata.
    func testAnUnterminatedFrontmatterOpenerIsNotFrontmatter() {
        XCTAssertTrue(styled("---\nid: 1\nbody with no close\n", .frontmatter).isEmpty)
    }
}
