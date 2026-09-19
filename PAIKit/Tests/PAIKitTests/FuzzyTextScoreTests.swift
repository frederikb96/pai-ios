import XCTest

@testable import PAIKit

/// The three behaviours that make a filter box feel like it works, and one that makes it feel
/// like it does not. Each is a property a refactor of the scorer could silently drop while every
/// other test here stayed green, and each is stated the way it was reported rather than as a
/// number the implementation also knows.
///
/// These mirror `pai-cloud/backend/tests/test_search.py`'s own cases for the same algorithm —
/// the two are one matcher written twice, so a divergence has to be a red suite somewhere.
final class FuzzyTextScoreTests: XCTestCase {

    private func score(_ query: String, _ field: String) -> Double {
        FuzzyTextScore.textScore(
            field: FuzzyField(folded: field.lowercased()),
            query: FuzzyQuery(normalized: query.lowercased()))
    }

    func testWordsMatchInAnyOrder() {
        XCTAssertGreaterThan(score("rollout sso", "KubeTalos SSO Rollout Execution"), 0)
        XCTAssertGreaterThan(score("sso rollout", "KubeTalos SSO Rollout Execution"), 0)
    }

    func testADroppedCharacterStillMatches() {
        XCTAssertGreaterThan(score("ssro", "KubeTalos SSO Rollout Execution"), 0)
    }

    func testATransposedPairStillMatches() {
        XCTAssertGreaterThan(score("sesison", "Session notes"), 0)
    }

    /// Typing has to narrow. Below the fuzzy floor almost every short word sits within one edit
    /// of almost every other, so tolerating an edit there would *widen* the list on the first
    /// keystroke — the one failure mode that makes a filter unusable rather than merely weak.
    func testAShortQueryDoesNotMatchANeighbourItIsOneEditFrom() {
        XCTAssertEqual(score("abc", "abd efg"), 0)
        // The same pair one character longer is inside the floor and does match, which is what
        // shows the zero above comes from the floor rather than from nothing matching at all.
        XCTAssertGreaterThan(score("abcd", "abce efg"), 0)
    }

    func testAnUnrelatedQueryDoesNotMatch() {
        XCTAssertEqual(score("kubernetes", "Grocery list"), 0)
    }

    /// The tiers exist so a title that *is* the query outranks one that merely contains its
    /// words. Asserted as an ordering, not as the constants — the constants are one Edit away
    /// and a test naming them would break on every retune while proving nothing.
    func testExactBeatsPrefixBeatsSubstringBeatsScatteredWords() {
        let exact = score("meeting notes", "Meeting notes")
        let prefixed = score("meeting notes", "Meeting notes from Tuesday")
        let contained = score("meeting notes", "Tuesday meeting notes archive")
        let scattered = score("meeting notes", "Notes from the Tuesday meeting")

        XCTAssertGreaterThan(exact, prefixed)
        XCTAssertGreaterThan(prefixed, contained)
        XCTAssertGreaterThan(contained, scattered)
        XCTAssertGreaterThan(scattered, 0)
    }

    func testASecondaryFieldScoresBelowTheSameHitOnThePrimaryOne() {
        let query = FuzzyQuery(normalized: "kubernetes")
        let field = FuzzyField(folded: "notes about kubernetes")
        let primary = FuzzyTextScore.textScore(field: field, query: query)
        let secondary = FuzzyTextScore.secondaryScore(field: field, query: query)

        XCTAssertGreaterThan(primary, secondary)
        XCTAssertGreaterThan(secondary, 0)
    }

    /// The bounded walk is an optimisation over the plain matrix, and the one way it can go
    /// wrong is silent: a pair inside the budget answered as if it were outside would simply
    /// stop matching, with nothing to see. So the two forms have to agree wherever the answer
    /// is within the budget.
    func testTheBoundedWalkAgreesWithTheUnboundedOneInsideTheBudget() {
        let words = ["session", "sesion", "sesison", "rollout", "sso", "", "kubetalos", "abcdefgh"]
        for a in words {
            for b in words {
                let full = FuzzyTextScore.editDistance(a, b)
                for limit in 0...3 {
                    let bounded = FuzzyTextScore.editDistance(a, b, limit: limit)
                    if full <= limit {
                        XCTAssertEqual(bounded, full, "\(a)/\(b) limit \(limit)")
                    } else {
                        XCTAssertGreaterThan(bounded, limit, "\(a)/\(b) limit \(limit)")
                    }
                }
            }
        }
    }

    func testEditDistanceCountsATranspositionAsOne() {
        XCTAssertEqual(FuzzyTextScore.editDistance("sesison", "session"), 1)
    }

    /// An ASCII word class would split a diacritic-bearing name into single letters, and a token
    /// per letter matches everything — the opposite of filtering.
    func testWordSplittingKeepsNonAsciiLettersTogether() {
        XCTAssertEqual(FuzzyTextScore.words("Müller-Straße 12_ok"), ["Müller", "Straße", "12", "ok"])
    }
}
