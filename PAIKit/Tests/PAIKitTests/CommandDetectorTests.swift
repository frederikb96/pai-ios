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

    // MARK: - The core positive case

    func testAFinalPhraseAtTheEndOfTheUtteranceFires() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "please Kai stop", isFinal: true, wordTimes: wordTimes(count: 3, gapSeconds: 0.6, sampleRate: rate),
            atOffset: 1000)
        XCTAssertEqual(detector.detect(observation)?.kind, .stop)
    }

    // MARK: - The position gate: nothing spoken after it

    func testAPhraseNotAtTheEndOfTheUtteranceDoesNotFire() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "Kai stop the music please", isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertNil(detector.detect(observation), "\"stop\" here is the object of a longer sentence, not a command")
    }

    // MARK: - Mid-sentence mentions must never fire — the central false-trigger risk

    func testTalkingAboutKaiMidSentenceNeverFires() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "I was telling my colleague that Kai could start handling this for us",
            isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertNil(detector.detect(observation))
    }

    func testMentioningStopWithoutTheWakeWordNeverFires() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(text: "we should stop", isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertNil(detector.detect(observation), "\"stop\" alone is not the configured phrase")
    }

    // MARK: - The pause gate

    func testNoPauseBeforeThePhraseSuppressesIt() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate, pauseGateSeconds: 0.4)
        // Every word butts up against the last with no gap at all.
        let observation = CommandObservation(
            text: "please Kai stop", isFinal: true, wordTimes: wordTimes(count: 3, gapSeconds: 0, sampleRate: rate),
            atOffset: 1000)
        XCTAssertNil(detector.detect(observation), "no pause before the phrase — likely spoken as part of the sentence")
    }

    func testAPauseAtLeastAsLongAsTheGateLetsItThrough() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate, pauseGateSeconds: 0.4)
        let observation = CommandObservation(
            text: "please Kai stop", isFinal: true, wordTimes: wordTimes(count: 3, gapSeconds: 0.5, sampleRate: rate),
            atOffset: 1000)
        XCTAssertEqual(detector.detect(observation)?.kind, .stop)
    }

    func testAPhraseOpeningTheUtteranceNeedsNoPrecedingPause() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate, pauseGateSeconds: 0.4)
        let observation = CommandObservation(
            text: "Kai stop", isFinal: true, wordTimes: wordTimes(count: 2, gapSeconds: 0, sampleRate: rate),
            atOffset: 1000)
        XCTAssertEqual(detector.detect(observation)?.kind, .stop)
    }

    func testMissingWordTimingSkipsThePauseGateRatherThanRefusing() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate, pauseGateSeconds: 0.4)
        let observation = CommandObservation(text: "please Kai stop", isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertEqual(
            detector.detect(observation)?.kind, .stop, "an engine with no timestamps still has the position gate")
    }

    // MARK: - Final-vs-volatile policy

    func testStartDoesNotFireOnAVolatileResult() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(text: "Kai start", isFinal: false, wordTimes: nil, atOffset: 1000)
        XCTAssertNil(detector.detect(observation))
    }

    func testSkipFiresOnAVolatileResult() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(text: "Kai skip", isFinal: false, wordTimes: nil, atOffset: 1000)
        XCTAssertEqual(detector.detect(observation)?.kind, .skip, "skip trades false positives for lower latency")
    }

    // MARK: - Dedup across repeated deliveries of the same growing utterance

    func testTheSamePhraseAtTheSameOffsetDoesNotFireTwice() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(text: "Kai stop", isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertNotNil(detector.detect(observation))
        XCTAssertNil(detector.detect(observation), "a repeated delivery of the same result must not refire")
    }

    func testANewOffsetAfterAFireCanFireAgain() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        _ = detector.detect(CommandObservation(text: "Kai stop", isFinal: true, wordTimes: nil, atOffset: 1000))
        let second = detector.detect(
            CommandObservation(text: "Kai start", isFinal: true, wordTimes: nil, atOffset: 2000))
        XCTAssertEqual(second?.kind, .start)
    }

    // MARK: - German variants and updated phrases

    func testTheGermanVariantFires() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(text: "also Kai stopp", isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertEqual(detector.detect(observation)?.kind, .stop)
    }

    func testACustomPhraseSetAtInitIsWhatTheDetectorMatchesAgainst() {
        var phrases = CommandPhraseSet.defaults.phrases
        phrases[.end] = "Jarvis goodbye"
        var detector = CommandDetector(phraseSet: CommandPhraseSet(phrases: phrases), sampleRate: rate)

        let old = detector.detect(CommandObservation(text: "Kai end", isFinal: true, wordTimes: nil, atOffset: 1000))
        XCTAssertNil(old, "the default phrase should not match once the phrase set overrides it")

        let new = detector.detect(
            CommandObservation(text: "Jarvis goodbye", isFinal: true, wordTimes: nil, atOffset: 2000))
        XCTAssertEqual(new?.kind, .end)
    }
}
