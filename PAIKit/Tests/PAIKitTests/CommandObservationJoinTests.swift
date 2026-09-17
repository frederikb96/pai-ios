import XCTest
@testable import PAIKit

final class CommandObservationJoinTests: XCTestCase {
    private let rate: Double = 16_000

    // MARK: - shouldJoin

    func testAGapUnderTheThresholdShouldJoin() {
        XCTAssertTrue(
            CommandObservationJoin.shouldJoin(
                previousSegmentEnd: 0, currentSegmentStart: Int(rate * 1), sampleRate: rate))
    }

    func testAGapAtOrOverTheThresholdShouldNotJoin() {
        XCTAssertFalse(
            CommandObservationJoin.shouldJoin(
                previousSegmentEnd: 0, currentSegmentStart: Int(rate * 2), sampleRate: rate))
    }

    // MARK: - joinedObservation

    /// The actual scenario this exists for: "...fix the bug, computer send" committed, then "the
    /// message..." a moment later — split across the boundary, neither half a configured phrase
    /// on its own, but whole once joined. A real pause sits before "computer" (Freddy's own
    /// deliberate one before the command), so this also clears the pause gate on its own.
    func testAPhraseSplitAcrossTheJoinIsFoundWhole() {
        let previousWords = [
            Word(range: 0..<4_800, text: "fix"), Word(range: 4_800..<9_600, text: "the"),
            Word(range: 9_600..<14_400, text: "bug"), Word(range: 20_800..<25_600, text: "computer"),
            Word(range: 25_600..<30_400, text: "send"),
        ]
        let currentWords = [Word(range: 36_400..<41_200, text: "the"), Word(range: 41_200..<46_000, text: "message")]
        let currentText = currentWords.map(\.text).joined(separator: " ")

        let observation = CommandObservationJoin.joinedObservation(
            previousWords: previousWords, currentText: currentText, currentWordTimes: currentWords.map(\.range),
            currentAtOffset: 46_000)

        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let outcomes = detector.detect(observation)
        let acceptedKinds = outcomes.compactMap { outcome -> CommandKind? in
            guard case .accepted(let event) = outcome else { return nil }
            return event.kind
        }
        XCTAssertEqual(acceptedKinds, [.send])
    }

    func testNoPreviousWordsLeavesTheObservationAsTheCurrentSegmentAlone() {
        let currentWords = [Word(range: 0..<4_800, text: "computer"), Word(range: 4_800..<9_600, text: "skip")]
        let observation = CommandObservationJoin.joinedObservation(
            previousWords: [], currentText: "computer skip", currentWordTimes: currentWords.map(\.range),
            currentAtOffset: 9_600)
        XCTAssertEqual(observation.text, "computer skip")
        XCTAssertEqual(observation.wordTimes, currentWords.map(\.range))
    }

    /// Never more than the cap — a whole earlier segment could be long, and only the phrase's own
    /// length could ever need joining.
    func testTrailingWordsAreCappedRegardlessOfHowLongThePreviousSegmentWas() {
        let previousWords = (0..<20).map { Word(range: ($0 * 1_000)..<($0 * 1_000 + 500), text: "word\($0)") }
        let observation = CommandObservationJoin.joinedObservation(
            previousWords: previousWords, currentText: "computer skip the message", currentWordTimes: nil,
            currentAtOffset: 40_000)
        let joinedWordCount = observation.text.split(separator: " ").count
        XCTAssertEqual(joinedWordCount, CommandObservationJoin.maxTrailingWords + 4)
    }

    /// A phrase entirely inside the previous segment's own words was already found (or correctly
    /// rejected) while that segment was itself processed — joining it again as a prefix must not
    /// let it fire a second time now that it no longer reaches the end of the combined text.
    func testAPhraseFullyInsideThePrefixIsNotRefiredBecauseItNoLongerReachesTheEnd() {
        let previousWords = [
            Word(range: 0..<4_800, text: "computer"), Word(range: 4_800..<9_600, text: "send"),
            Word(range: 9_600..<14_400, text: "the"), Word(range: 14_400..<19_200, text: "message"),
        ]
        let currentWords = [Word(range: 30_000..<34_800, text: "okay")]
        let observation = CommandObservationJoin.joinedObservation(
            previousWords: previousWords, currentText: "okay", currentWordTimes: currentWords.map(\.range),
            currentAtOffset: 34_800)

        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let outcomes = detector.detect(observation)
        XCTAssertTrue(
            outcomes.allSatisfy { if case .accepted = $0 { return false } else { return true } },
            "the phrase is no longer the last thing in the joined text, so it must not accept")
    }
}
