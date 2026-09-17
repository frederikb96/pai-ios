import XCTest
@testable import PAIKit

final class CommandGrammarTests: XCTestCase {
    // MARK: - normalize

    func testNormalizeFoldsCaseAndPunctuation() {
        XCTAssertEqual(CommandGrammar.normalize("Computer, SEND the message!"), "computer send the message")
        XCTAssertEqual(CommandGrammar.normalize("  Computer   stop  "), "computer stop")
    }

    /// A device log showed the transcript rendering its own sentence-ending punctuation as a
    /// full-width CJK character rather than a period — the whitelist-based filter (keep
    /// alphanumerics, drop everything else) must fold that the same way as any other punctuation.
    func testNormalizeFoldsCJKPunctuation() {
        XCTAssertEqual(CommandGrammar.normalize("computer send the message。"), "computer send the message")
        XCTAssertEqual(CommandGrammar.normalize("computer、send the message"), "computer send the message")
    }

    func testNormalizePreservesWordCountAgainstTheRawWhitespaceSplit() {
        // CommandDetector's stripping depends on this: normalize must never merge or split a
        // word, only trim/fold it.
        let raw = "Computer, please send the message now."
        XCTAssertEqual(CommandGrammar.normalize(raw).split(separator: " ").count, raw.split(separator: " ").count)
    }

    // MARK: - matches

    func testMatchesFindsAConfiguredPhrase() {
        let matches = CommandGrammar.matches(in: "please computer stop the message now", phraseSet: .defaults)
        XCTAssertEqual(matches.map(\.kind), [.stop])
        XCTAssertEqual(matches.first?.range, 1..<5)
    }

    func testMatchesNeverFiresOnAFragmentInsideALongerWord() {
        let matches = CommandGrammar.matches(in: "the computerized system stopped", phraseSet: .defaults)
        XCTAssertTrue(matches.isEmpty, "\"computerized\" must not match \"computer\"")
    }

    /// "Computer, send the message." with trailing punctuation and a comma folds to exactly the
    /// configured phrase — the false-trigger risk this whole gate exists to avoid is a bare
    /// mention of "computer", not a fully punctuated command sentence like this one.
    func testMatchesFindsThePhraseThroughPunctuation() {
        let matches = CommandGrammar.matches(in: "Computer, send the message.", phraseSet: .defaults)
        XCTAssertEqual(matches.map(\.kind), [.send])
    }

    func testMatchesFindsTheEndVariant() {
        let matches = CommandGrammar.matches(in: "computer end the message", phraseSet: .defaults)
        XCTAssertEqual(matches.map(\.kind), [.end])
    }

    func testMatchesDistinguishesInterruptOnFromInterruptOff() {
        XCTAssertEqual(
            CommandGrammar.matches(in: "computer interrupt on", phraseSet: .defaults).map(\.kind), [.interruptOn])
        XCTAssertEqual(
            CommandGrammar.matches(in: "computer interrupt off", phraseSet: .defaults).map(\.kind), [.interruptOff])
    }

    func testMatchesFindsMultipleDistinctCommandsInOneUtterance() {
        let matches = CommandGrammar.matches(
            in: "computer start the message and then later computer stop the message", phraseSet: .defaults)
        XCTAssertEqual(matches.map(\.kind), [.start, .stop])
    }

    func testMatchesRespectsACustomPhraseSet() {
        var phrases = CommandPhraseSet.defaults.phrases
        phrases[.send] = "Jarvis go ahead"
        let phraseSet = CommandPhraseSet(phrases: phrases)

        XCTAssertTrue(
            CommandGrammar.matches(in: "Jarvis go ahead please", phraseSet: phraseSet).contains { $0.kind == .send })
        XCTAssertTrue(
            CommandGrammar.matches(in: "computer send the message", phraseSet: phraseSet).isEmpty,
            "the default phrase should stop matching once overridden")
    }

    func testMatchesReturnsEmptyForOrdinaryTextAboutTheseTopics() {
        // The false-trigger risk this whole gate exists for: talking about computers without
        // addressing one as a command.
        let matches = CommandGrammar.matches(
            in: "we were discussing how a computer could start automating this workflow", phraseSet: .defaults)
        XCTAssertTrue(matches.isEmpty)
    }
}
