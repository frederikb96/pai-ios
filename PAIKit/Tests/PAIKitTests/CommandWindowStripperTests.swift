import XCTest
@testable import PAIKit

final class CommandWindowStripperTests: XCTestCase {
    private let rate: Double = 16_000

    private func word(_ text: String, at offset: Int, durationSamples: Int = 4_800) -> Word {
        Word(range: offset..<(offset + durationSamples), text: text)
    }

    func testWordsInsideACommandWindowAndMatchingItsVocabularyAreDropped() {
        let words = [
            word("write", at: 0), word("a", at: 5_000), word("summary", at: 10_000),
            word("Kai", at: 20_000), word("stop", at: 25_000),
        ]
        let commands = [CommandEvent(kind: .stop, atOffset: 22_000, confidence: 1)]

        let result = CommandWindowStripper.strip(
            words: words, commands: commands, phraseSet: .defaults, sampleRate: rate)
        XCTAssertEqual(result, "write a summary")
    }

    func testAWordOutsideEveryWindowSurvives() {
        let words = [word("Kai", at: 0), word("stop", at: 5_000), word("later", at: 200_000)]
        let commands = [CommandEvent(kind: .stop, atOffset: 2_500, confidence: 1)]

        let result = CommandWindowStripper.strip(
            words: words, commands: commands, phraseSet: .defaults, sampleRate: rate)
        XCTAssertEqual(result, "later")
    }

    func testACoincidentalWordInsideTheWindowButNotInTheCommandsVocabularySurvives() {
        // "meeting" happens to land inside the stop command's window, but "meeting" is not part
        // of any configured phrase, so the text-match half of the gate must keep it.
        let words = [word("Kai", at: 0), word("stop", at: 5_000), word("meeting", at: 6_000)]
        let commands = [CommandEvent(kind: .stop, atOffset: 2_500, confidence: 1)]

        let result = CommandWindowStripper.strip(
            words: words, commands: commands, phraseSet: .defaults, sampleRate: rate)
        XCTAssertEqual(result, "meeting")
    }

    func testAWordMatchingTheVocabularyOfADifferentCommandThanTheOneWhoseWindowItIsInSurvives() {
        // "start" sits inside the stop command's time window but is not part of the stop
        // vocabulary — it must not be dropped just because some command fired near it.
        let words = [word("Kai", at: 0), word("stop", at: 5_000), word("start", at: 6_000)]
        let commands = [CommandEvent(kind: .stop, atOffset: 2_500, confidence: 1)]

        let result = CommandWindowStripper.strip(
            words: words, commands: commands, phraseSet: .defaults, sampleRate: rate)
        XCTAssertEqual(result, "start")
    }

    func testNoCommandsLeavesTheTranscriptUntouched() {
        let words = [word("hello", at: 0), word("world", at: 5_000)]
        let result = CommandWindowStripper.strip(words: words, commands: [], phraseSet: .defaults, sampleRate: rate)
        XCTAssertEqual(result, "hello world")
    }

    func testMultipleCommandsEachStripTheirOwnWindow() {
        let words = [
            word("Kai", at: 0), word("start", at: 5_000),
            word("hello", at: 100_000),
            word("Kai", at: 200_000), word("stop", at: 205_000),
        ]
        let commands = [
            CommandEvent(kind: .start, atOffset: 2_500, confidence: 1),
            CommandEvent(kind: .stop, atOffset: 202_500, confidence: 1),
        ]
        let result = CommandWindowStripper.strip(
            words: words, commands: commands, phraseSet: .defaults, sampleRate: rate)
        XCTAssertEqual(result, "hello")
    }
}
