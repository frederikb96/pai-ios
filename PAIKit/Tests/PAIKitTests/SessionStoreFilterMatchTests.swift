import XCTest
@testable import PAIKit

/// `looksLikeIdFragment`'s 8-character floor is what stops an ordinary title search from being
/// silently routed client-side-only — the boundary itself, and the specific short hex words the
/// floor exists to rule out, are exactly what a refactor of the pattern could get subtly wrong.
final class SessionStoreFilterMatchTests: XCTestCase {

    // MARK: - looksLikeIdFragment

    func testSevenHexCharactersIsNotAnIdFragment() {
        XCTAssertFalse(SessionFilterMatch.looksLikeIdFragment("1234567"))
    }

    func testEightHexCharactersIsAnIdFragment() {
        XCTAssertTrue(SessionFilterMatch.looksLikeIdFragment("12345678"))
    }

    func testEightCharacterDashesAndDigitsIsAnIdFragment() {
        XCTAssertTrue(SessionFilterMatch.looksLikeIdFragment("ab12-cd34"))
    }

    /// The exact words the 8-character floor exists to protect — all short, all-hex English
    /// words that would otherwise misroute a real title search into a client-only id lookup.
    func testShortAllHexEnglishWordsAreNotIdFragments() {
        for word in ["cafe", "dead", "face", "beef"] {
            XCTAssertFalse(SessionFilterMatch.looksLikeIdFragment(word), word)
        }
    }

    func testNonHexCharacterDisqualifiesAnOtherwiseLongEnoughQuery() {
        XCTAssertFalse(SessionFilterMatch.looksLikeIdFragment("session-name"))
    }

    func testWholeStringMustMatchNotJustAPrefix() {
        // A trailing space is trimmed; a trailing word character is not — the pattern must match
        // the whole (trimmed) string, not merely find a run of hex digits inside a longer query.
        XCTAssertTrue(SessionFilterMatch.looksLikeIdFragment("  12345678  "))
        XCTAssertFalse(SessionFilterMatch.looksLikeIdFragment("12345678 sessions"))
    }

    func testEmptyAndWhitespaceOnlyAreNotIdFragments() {
        XCTAssertFalse(SessionFilterMatch.looksLikeIdFragment(""))
        XCTAssertFalse(SessionFilterMatch.looksLikeIdFragment("   "))
    }

    func testUppercaseHexIsStillAnIdFragment() {
        XCTAssertTrue(SessionFilterMatch.looksLikeIdFragment("DEADBEEF"))
    }

    // MARK: - sessionIdMatches

    func testMatchesAgainstSessionIdSubstring() {
        let session = SessionFixture.make(id: "abcd1234-ef56")
        XCTAssertTrue(SessionFilterMatch.sessionIdMatches("cd1234", session: session))
    }

    func testMatchesAgainstClaudeSessionIdWhenSessionIdDoesNotMatch() {
        let session = SessionFixture.make(id: "abcd1234", claudeSessionId: "wxyz9999")
        XCTAssertTrue(SessionFilterMatch.sessionIdMatches("wxyz", session: session))
    }

    func testDoesNotMatchAnUnrelatedFragment() {
        let session = SessionFixture.make(id: "abcd1234", claudeSessionId: "wxyz9999")
        XCTAssertFalse(SessionFilterMatch.sessionIdMatches("ffffffff", session: session))
    }

    func testEmptyQueryMatchesEverySession() {
        let session = SessionFixture.make(id: "abcd1234")
        XCTAssertTrue(SessionFilterMatch.sessionIdMatches("", session: session))
        XCTAssertTrue(SessionFilterMatch.sessionIdMatches("   ", session: session))
    }

    func testMatchIsCaseInsensitive() {
        let session = SessionFixture.make(id: "ABCD1234")
        XCTAssertTrue(SessionFilterMatch.sessionIdMatches("abcd", session: session))
    }

    // MARK: - fuzzyMatchesSubsequence (directory filter)

    func testSubsequenceMatchAllowsGapsBetweenCharacters() {
        XCTAssertTrue(SessionFilterMatch.fuzzyMatchesSubsequence("pcl", "pai-cloud"))
    }

    func testSubsequenceMatchRequiresOrder() {
        XCTAssertFalse(SessionFilterMatch.fuzzyMatchesSubsequence("lcp", "pai-cloud"))
    }

    func testSubsequenceMatchIsCaseInsensitive() {
        XCTAssertTrue(SessionFilterMatch.fuzzyMatchesSubsequence("CLOUD", "pai-cloud"))
    }

    func testEmptyQueryMatchesEveryDirectory() {
        XCTAssertTrue(SessionFilterMatch.fuzzyMatchesSubsequence("", "anything"))
    }

    func testSubsequenceMatchFailsWhenACharacterIsMissing() {
        XCTAssertFalse(SessionFilterMatch.fuzzyMatchesSubsequence("pai-clouds", "pai-cloud"))
    }
}
