import XCTest

@testable import PAIKit

final class SpeechTextTests: XCTestCase {

    // MARK: - Markup already stripped by the block model

    func testEmphasisAndLinkMarkersDisappearButTheirTextSurvives() {
        let blocks = MarkdownParser.parse("Read the **docs** at [the site](https://example.com) today.")
        let speech = SpeechText.speakable(blocks)
        XCTAssertEqual(speech, "Read the docs at the site today.")
    }

    // MARK: - Code blocks and tables are announced, never read

    func testACodeBlockIsAnnouncedByLanguageAndLineCountRatherThanRead() {
        let blocks = MarkdownParser.parse(
            """
            ```swift
            let x = 1
            let y = 2
            ```
            """)
        XCTAssertEqual(SpeechText.speakable(blocks), "Code block, swift, 2 lines.")
    }

    func testACodeBlockWithNoLanguageOmitsTheLanguagePhraseEntirely() {
        let blocks = MarkdownParser.parse(
            """
            ```
            one line
            ```
            """)
        XCTAssertEqual(SpeechText.speakable(blocks), "Code block, 1 line.")
    }

    func testATableIsAnnouncedByItsShapeRatherThanReadCellByCell() {
        let blocks = MarkdownParser.parse(
            """
            | a | b | c |
            |---|---|---|
            | 1 | 2 | 3 |
            | 4 | 5 | 6 |
            """)
        XCTAssertEqual(SpeechText.speakable(blocks), "Table, 2 rows, 3 columns.")
    }

    /// Freddy's own instruction: nothing is ever silently dropped, code blocks and tables
    /// included — they are announced instead of read, never skipped outright.
    func testNeitherACodeBlockNorATableProducesEmptyText() {
        let codeBlocks = MarkdownParser.parse("```\nsome code\n```")
        let tableBlocks = MarkdownParser.parse("| a |\n|---|\n| 1 |")
        XCTAssertFalse(SpeechText.speakable(codeBlocks).isEmpty)
        XCTAssertFalse(SpeechText.speakable(tableBlocks).isEmpty)
    }

    // MARK: - Lists

    func testListItemsLoseTheirBulletsAndReadAsFlowingProse() {
        let blocks = MarkdownParser.parse("- first thing\n- second thing")
        XCTAssertEqual(SpeechText.speakable(blocks), "first thing. second thing.")
    }

    func testOrderedListItemsLoseTheirNumbersToo() {
        let blocks = MarkdownParser.parse("1. alpha\n2. beta")
        XCTAssertEqual(SpeechText.speakable(blocks), "alpha. beta.")
    }

    // MARK: - Structural blocks that carry no linear reading

    func testAThematicBreakProducesNoTextOfItsOwn() {
        let blocks = MarkdownParser.parse("above\n\n---\n\nbelow")
        XCTAssertEqual(SpeechText.speakable(blocks), "above. below.")
    }

    func testAnHtmlBlockIsAnnouncedRatherThanReadAsTags() {
        let blocks = MarkdownParser.parse("<div>\n  <span>hi</span>\n</div>")
        let speech = SpeechText.speakable(blocks)
        XCTAssertTrue(speech.hasPrefix("HTML block,"), "expected an HTML-block announcement, got: \(speech)")
        XCTAssertFalse(speech.contains("<div>"))
    }

    // MARK: - Emoji stripped, digits and punctuation untouched

    func testEmojiIsStrippedButDigitsAndPunctuationSurvive() {
        let blocks = MarkdownParser.parse("Costs about $0.39/hour \u{1F680} for now.")
        let speech = SpeechText.speakable(blocks)
        XCTAssertEqual(speech, "Costs about $0.39/hour for now.")
    }

    func testADigitNextToARealEmojiKeepsTheDigitAndDropsOnlyTheEmoji() {
        let blocks = MarkdownParser.parse("Step 1 \u{1F680} done.")
        let speech = SpeechText.speakable(blocks)
        XCTAssertTrue(speech.contains("1"), "expected the digit to survive, got: \(speech)")
        XCTAssertFalse(speech.contains("\u{1F680}"))
    }

    // MARK: - Sentence splitting for SendTextMulti

    func testSentencesSplitsOnTerminatingPunctuationAndTrimsWhitespace() {
        let sentences = SpeechText.sentences(of: "Hello there. How are you?  I am fine!")
        XCTAssertEqual(sentences, ["Hello there.", "How are you?", "I am fine!"])
    }

    func testSentencesKeepsATrailingFragmentWithNoTerminatingPunctuation() {
        let sentences = SpeechText.sentences(of: "Hello there. and then a fragment with no ending")
        XCTAssertEqual(sentences, ["Hello there.", "and then a fragment with no ending"])
    }

    func testSentencesOfEmptyTextIsEmpty() {
        XCTAssertEqual(SpeechText.sentences(of: "   "), [])
    }

    // MARK: - Nothing dropped: every block contributes something

    func testABlockQuoteIsNotSilentlyDropped() {
        let blocks = MarkdownParser.parse("> quoted text here")
        XCTAssertTrue(SpeechText.speakable(blocks).contains("quoted text here"))
    }

    func testAHeadingReadsAsAnOrdinarySentence() {
        let blocks = MarkdownParser.parse("## A Heading")
        XCTAssertEqual(SpeechText.speakable(blocks), "A Heading.")
    }
}
