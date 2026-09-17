import XCTest
@testable import PAIKit

final class CommandWindowStripperTests: XCTestCase {
    private let rate: Double = 16_000

    private func word(_ text: String, at offset: Int, durationSamples: Int = 4_800) -> Word {
        Word(range: offset..<(offset + durationSamples), text: text)
    }

    // MARK: - Precise stripping via `phraseRange`, the ordinary case

    /// The matched phrase's own words are dropped exactly, and nothing outside its span — even
    /// though "the" and "message" are common enough that a fixed time window plus vocabulary
    /// match alone could over-reach into ordinary dictation nearby.
    func testWordsInsideAPhraseRangeAreDroppedAndNothingElseIs() {
        let words = [
            word("write", at: 0), word("a", at: 5_000), word("summary", at: 10_000),
            word("computer", at: 20_000), word("stop", at: 25_000), word("the", at: 30_000),
            word("message", at: 35_000),
        ]
        let commands = [CommandEvent(kind: .stop, atOffset: 20_000, confidence: 1, phraseRange: 20_000..<39_800)]

        let result = CommandWindowStripper.strip(
            words: words, commands: commands, phraseSet: .defaults, sampleRate: rate)
        XCTAssertEqual(result, "write a summary")
    }

    /// A word sharing text with the phrase's own vocabulary, but well outside the phrase's own
    /// span, survives — precise stripping never falls back to a vocabulary-wide sweep once a
    /// `phraseRange` is known.
    func testAWordSharingVocabularyButOutsideThePhraseRangeSurvives() {
        let words = [
            word("computer", at: 0), word("stop", at: 5_000), word("the", at: 10_000), word("message", at: 15_000),
            word("about", at: 200_000), word("the", at: 205_000), word("message", at: 210_000),
        ]
        let commands = [CommandEvent(kind: .stop, atOffset: 0, confidence: 1, phraseRange: 0..<19_800)]

        let result = CommandWindowStripper.strip(
            words: words, commands: commands, phraseSet: .defaults, sampleRate: rate)
        XCTAssertEqual(result, "about the message")
    }

    // MARK: - The fallback: vocabulary plus a time window, when no `phraseRange` is known

    func testWithNoPhraseRangeAVocabularyMatchInsideTheWindowIsDropped() {
        let words = [
            word("write", at: 0), word("a", at: 5_000), word("summary", at: 10_000),
            word("computer", at: 20_000), word("stop", at: 25_000),
        ]
        let commands = [CommandEvent(kind: .stop, atOffset: 22_000, confidence: 1)]

        let result = CommandWindowStripper.strip(
            words: words, commands: commands, phraseSet: .defaults, sampleRate: rate)
        XCTAssertEqual(result, "write a summary")
    }

    func testWithNoPhraseRangeAWordOutsideEveryWindowSurvives() {
        let words = [word("computer", at: 0), word("stop", at: 5_000), word("later", at: 300_000)]
        let commands = [CommandEvent(kind: .stop, atOffset: 2_500, confidence: 1)]

        let result = CommandWindowStripper.strip(
            words: words, commands: commands, phraseSet: .defaults, sampleRate: rate)
        XCTAssertEqual(result, "later")
    }

    func testWithNoPhraseRangeACoincidentalWordInsideTheWindowButNotInTheCommandsVocabularySurvives() {
        // "meeting" happens to land inside the stop command's window, but "meeting" is not part
        // of any configured phrase, so the text-match half of the fallback must keep it.
        let words = [word("computer", at: 0), word("stop", at: 5_000), word("meeting", at: 6_000)]
        let commands = [CommandEvent(kind: .stop, atOffset: 2_500, confidence: 1)]

        let result = CommandWindowStripper.strip(
            words: words, commands: commands, phraseSet: .defaults, sampleRate: rate)
        XCTAssertEqual(result, "meeting")
    }

    func testWithNoPhraseRangeAWordMatchingTheVocabularyOfADifferentCommandThanTheOneWhoseWindowItIsInSurvives() {
        // "skip" sits inside the stop command's time window but is not part of the stop
        // vocabulary — it must not be dropped just because some command fired near it.
        let words = [word("computer", at: 0), word("stop", at: 5_000), word("skip", at: 6_000)]
        let commands = [CommandEvent(kind: .stop, atOffset: 2_500, confidence: 1)]

        let result = CommandWindowStripper.strip(
            words: words, commands: commands, phraseSet: .defaults, sampleRate: rate)
        XCTAssertEqual(result, "skip")
    }

    func testNoCommandsLeavesTheTranscriptUntouched() {
        let words = [word("hello", at: 0), word("world", at: 5_000)]
        let result = CommandWindowStripper.strip(words: words, commands: [], phraseSet: .defaults, sampleRate: rate)
        XCTAssertEqual(result, "hello world")
    }

    func testMultipleCommandsEachStripTheirOwnRange() {
        let words = [
            word("computer", at: 0), word("start", at: 5_000), word("the", at: 10_000), word("message", at: 15_000),
            word("hello", at: 100_000),
            word("computer", at: 200_000), word("stop", at: 205_000), word("the", at: 210_000),
            word("message", at: 215_000),
        ]
        let commands = [
            CommandEvent(kind: .start, atOffset: 0, confidence: 1, phraseRange: 0..<19_800),
            CommandEvent(kind: .stop, atOffset: 200_000, confidence: 1, phraseRange: 200_000..<219_800),
        ]
        let result = CommandWindowStripper.strip(
            words: words, commands: commands, phraseSet: .defaults, sampleRate: rate)
        XCTAssertEqual(result, "hello")
    }
}
