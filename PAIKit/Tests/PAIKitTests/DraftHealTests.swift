import XCTest

@testable import PAIKit

final class DraftHealTests: XCTestCase {

    /// The core case: a take's own previously-inserted text, still sitting untouched in the
    /// draft, is replaced in place with the healed version — nothing before or after it moves.
    func testReplacesThePreviousTextInPlaceWhenStillPresent() {
        let outcome = DraftHeal.heal(
            currentDraftText: "before stt-rec: hello … world after",
            previousInsertedText: "stt-rec: hello … world",
            healedText: "stt-rec: hello there world"
        )
        XCTAssertEqual(outcome, .replaced("before stt-rec: hello there world after"))
    }

    /// The sharp case this type exists to make impossible: a take's text that has already been
    /// edited since it was inserted must never be duplicated by an unrelated append — it is
    /// simply not found, and the caller's job is to say so, not to guess where it went.
    func testEditedTextIsNotFoundRatherThanDuplicated() {
        let outcome = DraftHeal.heal(
            currentDraftText: "before stt-rec: hello EDITED world after",
            previousInsertedText: "stt-rec: hello … world",
            healedText: "stt-rec: hello there world"
        )
        XCTAssertEqual(outcome, .notFound)
    }

    /// Sent (or cleared) since — the draft simply no longer contains the take's text at all.
    func testAClearedDraftIsNotFound() {
        let outcome = DraftHeal.heal(
            currentDraftText: "", previousInsertedText: "stt-rec: hello", healedText: "stt-rec: hello there"
        )
        XCTAssertEqual(outcome, .notFound)
    }

    /// A take that never actually inserted anything (recovered at launch with no known prior
    /// state) has nothing to find — an empty `previousInsertedText` is always `.notFound`, never
    /// treated as "matches everywhere".
    func testEmptyPreviousTextIsAlwaysNotFound() {
        let outcome = DraftHeal.heal(currentDraftText: "anything at all", previousInsertedText: "", healedText: "x")
        XCTAssertEqual(outcome, .notFound)
    }

    /// Only the take's own text changes — everything the draft held before and after it, added by
    /// something else entirely, survives untouched.
    func testSurroundingDraftContentIsPreservedExactly() {
        let outcome = DraftHeal.heal(
            currentDraftText: "notes before\nstt-rec: partial\nnotes after",
            previousInsertedText: "stt-rec: partial", healedText: "stt-rec: partial and more"
        )
        XCTAssertEqual(outcome, .replaced("notes before\nstt-rec: partial and more\nnotes after"))
    }

    /// A second heal pass (more gaps closing later) must find what the *first* heal pass wrote,
    /// not the take's original insertion — proving the replace-in-place chain composes rather
    /// than only working once.
    func testASecondHealFindsWhatTheFirstHealWroteNotTheOriginalInsertion() {
        let afterFirstHeal = DraftHeal.heal(
            currentDraftText: "stt-rec: hello … world", previousInsertedText: "stt-rec: hello … world",
            healedText: "stt-rec: hello there … world"
        )
        guard case let .replaced(draftAfterFirstHeal) = afterFirstHeal else {
            return XCTFail("expected the first heal to replace")
        }
        let afterSecondHeal = DraftHeal.heal(
            currentDraftText: draftAfterFirstHeal, previousInsertedText: "stt-rec: hello there … world",
            healedText: "stt-rec: hello there my friend world"
        )
        XCTAssertEqual(afterSecondHeal, .replaced("stt-rec: hello there my friend world"))
    }
}
