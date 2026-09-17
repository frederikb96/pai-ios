import XCTest
@testable import PAIKit

final class CommandDetectorTests: XCTestCase {
    private let rate: Double = 16_000

    /// One `SampleRange` per word, each `gapSeconds` after the previous word ends.
    private func wordTimes(count: Int, gapSeconds: Double, sampleRate: Double) -> [SampleRange] {
        var times: [SampleRange] = []
        var cursor = 0
        let wordSamples = Int(sampleRate * 0.3)
        let gapSamples = Int(sampleRate * gapSeconds)
        for index in 0..<count {
            if index > 0 { cursor += gapSamples }
            times.append(cursor..<(cursor + wordSamples))
            cursor += wordSamples
        }
        return times
    }

    private func accepted(_ outcome: CommandDetectionOutcome) -> CommandEvent? {
        guard case .accepted(let event) = outcome else { return nil }
        return event
    }

    // MARK: - The core positive case

    func testAFinalPhraseAtTheEndOfTheUtteranceFires() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "please computer stop the message", isFinal: true,
            wordTimes: wordTimes(count: 5, gapSeconds: 0.3, sampleRate: rate), atOffset: 1000)
        XCTAssertEqual(accepted(detector.detect(observation))?.kind, .stop)
    }

    /// A "send" closes the turn at the event's offset, so it must sit where the phrase began —
    /// not at the start of the segment, which would cut the words said before it.
    func testTheEventIsStampedWhereThePhraseBegins() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let times = wordTimes(count: 6, gapSeconds: 0.3, sampleRate: rate)
        let observation = CommandObservation(
            text: "deploy it computer send the message", isFinal: true, wordTimes: times, atOffset: times[5].upperBound)
        XCTAssertEqual(accepted(detector.detect(observation))?.atOffset, times[2].lowerBound)
    }

    /// The phrase's own words, and only those, are captured — not the words before or after it —
    /// so `CommandWindowStripper` can drop exactly the command and nothing else.
    func testThePhraseRangeSpansExactlyTheMatchedWords() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let times = wordTimes(count: 6, gapSeconds: 0.3, sampleRate: rate)
        let observation = CommandObservation(
            text: "deploy it computer send the message", isFinal: true, wordTimes: times, atOffset: times[5].upperBound)
        let event = accepted(detector.detect(observation))
        XCTAssertEqual(event?.phraseRange, times[2].lowerBound..<times[5].upperBound)
    }

    func testMissingWordTimingLeavesThePhraseRangeNil() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "computer stop the message", isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertNil(accepted(detector.detect(observation))?.phraseRange)
    }

    // MARK: - The position gate: nothing spoken after it

    func testAPhraseNotAtTheEndOfTheUtteranceIsRejected() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "computer stop the message please", isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertEqual(
            detector.detect(observation), .rejected(kind: .stop, reason: .position),
            "the phrase here is followed by more words, so it is not the last thing said")
    }

    // MARK: - Mid-sentence mentions must never fire — the central false-trigger risk

    func testTalkingAboutComputersMidSentenceNeverFires() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "I was telling my colleague that a computer could start handling this for us",
            isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertEqual(detector.detect(observation), .none)
    }

    func testMentioningStopWithoutTheFullPhraseNeverFires() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(text: "we should stop", isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertEqual(detector.detect(observation), .none, "\"stop\" alone is not a configured phrase")
    }

    // MARK: - Final-vs-volatile policy

    func testStartDoesNotFireOnAVolatileResult() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "computer start the message", isFinal: false, wordTimes: nil, atOffset: 1000)
        XCTAssertEqual(detector.detect(observation), .rejected(kind: .start, reason: .notFinal))
    }

    func testSkipFiresOnAVolatileResult() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "computer skip the message", isFinal: false, wordTimes: nil, atOffset: 1000)
        XCTAssertEqual(
            accepted(detector.detect(observation))?.kind, .skip, "skip trades false positives for lower latency")
    }

    // MARK: - Dedup across repeated deliveries of the same growing utterance

    func testTheSamePhraseAtTheSameOffsetDoesNotFireTwice() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "computer stop the message", isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertNotNil(accepted(detector.detect(observation)))
        XCTAssertEqual(
            detector.detect(observation), .none, "a repeated delivery of the same result must not refire")
    }

    func testANewOffsetAfterAFireCanFireAgain() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        _ = detector.detect(
            CommandObservation(text: "computer stop the message", isFinal: true, wordTimes: nil, atOffset: 1000))
        let second = detector.detect(
            CommandObservation(text: "computer skip the message", isFinal: true, wordTimes: nil, atOffset: 2000))
        XCTAssertEqual(accepted(second)?.kind, .skip)
    }

    // MARK: - Custom phrase sets

    func testACustomPhraseSetAtInitIsWhatTheDetectorMatchesAgainst() {
        var phrases = CommandPhraseSet.defaults.phrases
        phrases[.end] = "Jarvis goodbye"
        var detector = CommandDetector(phraseSet: CommandPhraseSet(phrases: phrases), sampleRate: rate)

        let old = detector.detect(
            CommandObservation(text: "computer end the call", isFinal: true, wordTimes: nil, atOffset: 1000))
        XCTAssertEqual(old, .none, "the default phrase should not match once the phrase set overrides it")

        let new = detector.detect(
            CommandObservation(text: "Jarvis goodbye", isFinal: true, wordTimes: nil, atOffset: 2000))
        XCTAssertEqual(accepted(new)?.kind, .end)
    }

    // MARK: - Interrupt on/off are exempt from the position gate

    /// "Wait, wait. Computer interrupt on. That's so easy." — interrupt is said mid-dictation and
    /// the talking carries on, so the position gate must not apply to it.
    func testInterruptOnIsRecognisedMidSentence() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: 16_000)
        let observation = CommandObservation(
            text: "Wait, wait. Computer interrupt on. That's so easy.", isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertEqual(accepted(detector.detect(observation))?.kind, .interruptOn)
    }

    func testInterruptOffIsRecognisedMidSentence() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: 16_000)
        let observation = CommandObservation(
            text: "Computer interrupt off, that's better now.", isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertEqual(accepted(detector.detect(observation))?.kind, .interruptOff)
    }
}
