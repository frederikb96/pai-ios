import Foundation
import XCTest

@testable import PAIKit

final class SearchTextTests: XCTestCase {

    /// The invariant everything else rests on. If normalizing can lengthen text, every highlight
    /// range after the offending character lands in the wrong place — and only for text
    /// containing that character, which is why this would survive any amount of manual checking.
    ///
    /// Measured in UTF-16 units, because that is the unit the highlight ranges use.
    func testNormalizeNeverGrowsTheTextInUtf16Units() {
        let awkward = [
            "İstanbul",  // lowercases to i + combining dot: same character count, one more unit
            "STRASSE",
            "ﬁle",
            "Ω",
            "café CAFÉ",
            "🇩🇪 flag",
            "plain ASCII",
        ]

        for sample in awkward {
            XCTAssertLessThanOrEqual(
                SearchText.normalize(sample).utf16.count,
                sample.utf16.count,
                "normalizing \(sample) lengthened it, breaking the index mapping"
            )
        }
    }

    /// The specific character the guard exists for. Keeping it uppercase is the correct outcome:
    /// a missed case-insensitive match is acceptable, a corrupted offset is not.
    func testCharacterThatWouldGrowIsLeftAlone() {
        XCTAssertEqual(SearchText.normalize("İ"), "İ")
        XCTAssertEqual(SearchText.normalize("A"), "a", "ordinary lowercasing stopped working")
    }

    /// Whitespace runs collapse to one space, and the result has none at either end — the
    /// property that lets `containsMatch` skip trimming its query.
    func testWhitespaceCollapsesAndNeverEdgesTheResult() {
        XCTAssertEqual(SearchText.normalize("  a \n\t b  \n "), "a b")
        XCTAssertEqual(SearchText.normalize("   "), "")
    }

    /// A non-breaking space is deliberately *not* whitespace here, matching the reference
    /// implementation. If that ever changes it should be a decision, not a silent consequence of
    /// reaching for `Character.isWhitespace`.
    func testNonBreakingSpaceIsNotCollapsed() {
        XCTAssertEqual(SearchText.normalize("a\u{00a0}b"), "a\u{00a0}b")
    }

    /// Counting must not double-count overlaps, or the index disagrees with the walk over the
    /// rendered text about how many hits a message has — and navigation lands on a hit that the
    /// page cannot show.
    func testMatchesAreCountedWithoutOverlap() {
        XCTAssertEqual(SearchText.countMatches(haystack: "aaa", needle: "aa"), 1)
        XCTAssertEqual(SearchText.countMatches(haystack: "aaaa", needle: "aa"), 2)
        XCTAssertEqual(SearchText.countMatches(haystack: "abc", needle: ""), 0)
        XCTAssertEqual(SearchText.countMatches(haystack: "", needle: "a"), 0)
    }

    func testContainsMatchIgnoresCaseAndSpacing() {
        XCTAssertTrue(SearchText.containsMatch("The  Quick\nBrown", query: "quick brown"))
        XCTAssertFalse(SearchText.containsMatch("The Quick", query: "slow"))
        XCTAssertFalse(SearchText.containsMatch("anything", query: "   "), "a blank query matched")
    }

    // MARK: - Search text comes from the rendering

    /// A link's destination is not on screen, so searching for it must not claim a hit — search
    /// would then scroll to a message with nothing to highlight. The label is on screen and must
    /// match. This is the property that makes deriving search text from the block model, rather
    /// than from markdown source, worth doing.
    func testLinkUrlIsNotSearchableButItsLabelIs() {
        let blocks = MarkdownParser.parse("see [the docs](https://example.com/secret-path)")

        XCTAssertTrue(SearchText.containsMatch(blocks.plainText, query: "the docs"))
        XCTAssertFalse(
            SearchText.containsMatch(blocks.plainText, query: "secret-path"),
            "a URL that is never drawn was searchable"
        )
    }

    /// Code is displayed verbatim, so it is searchable verbatim — including the markers that
    /// emphasis would otherwise consume. An identifier is the commonest search in this app.
    func testCodeContentIsSearchableIncludingItsMarkers() {
        let blocks = MarkdownParser.parse("call `snake_case_name` and a*b\n\n```\nlet total = 1\n```")

        XCTAssertTrue(SearchText.containsMatch(blocks.plainText, query: "snake_case_name"))
        XCTAssertTrue(SearchText.containsMatch(blocks.plainText, query: "a*b"))
        XCTAssertTrue(SearchText.containsMatch(blocks.plainText, query: "let total"))
    }

    /// Markdown syntax renders as formatting, not as characters, so it must not be matchable —
    /// otherwise searching for `##` finds every heading and highlights nothing.
    func testMarkdownSyntaxItselfIsNotSearchable() {
        let blocks = MarkdownParser.parse("## Heading\n\n**bold** text\n\n---")

        XCTAssertTrue(SearchText.containsMatch(blocks.plainText, query: "heading"))
        XCTAssertTrue(SearchText.containsMatch(blocks.plainText, query: "bold text"))
        XCTAssertFalse(SearchText.containsMatch(blocks.plainText, query: "##"))
        XCTAssertFalse(SearchText.containsMatch(blocks.plainText, query: "**"))
    }

    // MARK: - findMatches (locating a hit, not just detecting one)

    func testFindMatchesLocatesEveryOccurrenceInSourceCoordinates() {
        let matches = SearchText.findMatches(in: "one two one", query: "one")
        XCTAssertEqual(matches, [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3)])
    }

    /// Search is case-insensitive, but a highlight has to land on the real string a view draws —
    /// so the located range must point at the original casing, not a lowercased copy.
    func testFindMatchesIsCaseInsensitiveButRangesPointAtTheOriginalCasing() {
        let text = "Hello WORLD"
        let matches = SearchText.findMatches(in: text, query: "world")
        XCTAssertEqual(matches, [NSRange(location: 6, length: 5)])
        XCTAssertEqual((text as NSString).substring(with: matches[0]), "WORLD")
    }

    /// A query spanning a collapsed whitespace run must locate the entire original run, not just
    /// the single space the normalized text matched against — otherwise the highlighted range
    /// would end short of what a reader actually searched for.
    func testFindMatchesSpansTheWholeOriginalWhitespaceRunNotJustOneSpace() {
        let matches = SearchText.findMatches(in: "a   b", query: "a b")
        XCTAssertEqual(matches, [NSRange(location: 0, length: 5)])
    }

    func testFindMatchesReturnsNothingForAnEmptyOrBlankQuery() {
        XCTAssertEqual(SearchText.findMatches(in: "anything", query: ""), [])
        XCTAssertEqual(SearchText.findMatches(in: "anything", query: "   "), [])
    }

    func testFindMatchesDoesNotOverlap() {
        let matches = SearchText.findMatches(in: "aaaa", query: "aa")
        XCTAssertEqual(matches, [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
    }

    /// The character `normalize(_:)` itself declines to lowercase (`testCharacterThatWouldGrowIsLeftAlone`)
    /// must still be located correctly by an exact-case query — the offset table has to stay
    /// correct even where normalization leaves a character untouched.
    func testFindMatchesLocatesTheGuardedUppercaseCharacter() {
        let text = "İstanbul is old"
        let matches = SearchText.findMatches(in: text, query: "İstanbul")
        let expectedLength = (text as NSString).range(of: "İstanbul").length
        XCTAssertEqual(matches, [NSRange(location: 0, length: expectedLength)])
    }
}
