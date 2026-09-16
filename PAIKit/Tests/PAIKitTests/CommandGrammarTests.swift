import XCTest
@testable import PAIKit

final class CommandGrammarTests: XCTestCase {
    // MARK: - normalize

    func testNormalizeFoldsCaseAndDiacriticsAndPunctuation() {
        XCTAssertEqual(CommandGrammar.normalize("Kai, STOP!"), "kai stop")
        XCTAssertEqual(CommandGrammar.normalize("Kaï stop"), "kai stop")
        XCTAssertEqual(CommandGrammar.normalize("  Kai   stop  "), "kai stop")
    }

    func testNormalizePreservesWordCountAgainstTheRawWhitespaceSplit() {
        // CommandDetector's pause gate depends on this: normalize must never merge or split a
        // word, only trim/fold it.
        let raw = "Hey Kai, please stop now."
        XCTAssertEqual(CommandGrammar.normalize(raw).split(separator: " ").count, raw.split(separator: " ").count)
    }

    // MARK: - matches

    func testMatchesFindsAConfiguredPhrase() {
        let matches = CommandGrammar.matches(in: "please Kai stop now", phraseSet: .defaults)
        XCTAssertEqual(matches.map(\.kind), [.stop])
        XCTAssertEqual(matches.first?.range, 1..<3)
    }

    func testMatchesNeverFiresOnAFragmentInsideALongerWord() {
        let matches = CommandGrammar.matches(in: "the Kaiser stopped", phraseSet: .defaults)
        XCTAssertTrue(matches.isEmpty, "\"Kaiser\" must not match \"Kai\"")
    }

    func testMatchesFindsTheGermanVariant() {
        let matches = CommandGrammar.matches(in: "also Kai stopp bitte", phraseSet: .defaults)
        XCTAssertEqual(matches.map(\.kind), [.stop])
    }

    func testMatchesFindsMultipleDistinctCommandsInOneUtterance() {
        let matches = CommandGrammar.matches(in: "Kai start and then later Kai stop", phraseSet: .defaults)
        XCTAssertEqual(matches.map(\.kind), [.start, .stop])
    }

    func testMatchesRespectsACustomPhraseSet() {
        var phrases = CommandPhraseSet.defaults.phrases
        phrases[.send] = "Jarvis go ahead"
        let phraseSet = CommandPhraseSet(phrases: phrases)

        XCTAssertTrue(
            CommandGrammar.matches(in: "Jarvis go ahead please", phraseSet: phraseSet).contains { $0.kind == .send })
        XCTAssertTrue(
            CommandGrammar.matches(in: "Kai send", phraseSet: phraseSet).isEmpty,
            "the default phrase should stop matching once overridden")
    }

    func testMatchesReturnsEmptyForOrdinaryTextAboutTheseTopics() {
        // The false-trigger risk this whole gate exists for: talking about computers and Kai
        // without addressing either as a command.
        let matches = CommandGrammar.matches(
            in: "we were discussing how Kai, our AI agent, could start automating this workflow",
            phraseSet: .defaults)
        XCTAssertTrue(matches.isEmpty)
    }
}
