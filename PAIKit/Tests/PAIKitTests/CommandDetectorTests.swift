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

    private func acceptedEvents(_ outcomes: [CommandDetectionOutcome]) -> [CommandEvent] {
        outcomes.compactMap { outcome in
            guard case .accepted(let event) = outcome else { return nil }
            return event
        }
    }

    private func onlyAccepted(_ outcomes: [CommandDetectionOutcome]) -> CommandEvent? {
        let events = acceptedEvents(outcomes)
        XCTAssertLessThanOrEqual(events.count, 1, "expected at most one accepted command")
        return events.first
    }

    // MARK: - The core positive case

    func testAFinalPhraseAtTheEndOfTheUtteranceFires() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "please computer stop the message", isFinal: true,
            wordTimes: wordTimes(count: 5, gapSeconds: 0.6, sampleRate: rate), atOffset: 1000)
        XCTAssertEqual(onlyAccepted(detector.detect(observation))?.kind, .stop)
    }

    /// A "send" closes the turn at the event's offset, so it must sit where the phrase began —
    /// not at the start of the segment, which would cut the words said before it.
    func testTheEventIsStampedWhereThePhraseBegins() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let times = wordTimes(count: 6, gapSeconds: 0.6, sampleRate: rate)
        let observation = CommandObservation(
            text: "deploy it computer send the message", isFinal: true, wordTimes: times, atOffset: times[5].upperBound)
        XCTAssertEqual(onlyAccepted(detector.detect(observation))?.atOffset, times[2].lowerBound)
    }

    func testAcceptedTranscriptEventsCarryTheTranscriptSource() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "please computer stop the message", isFinal: true,
            wordTimes: wordTimes(count: 5, gapSeconds: 0.6, sampleRate: rate), atOffset: 1000)
        XCTAssertEqual(onlyAccepted(detector.detect(observation))?.source, .transcript)
    }

    /// The phrase's own words, and only those, are captured — not the words before or after it —
    /// so `CommandWindowStripper` can drop exactly the command and nothing else.
    func testThePhraseRangeSpansExactlyTheMatchedWords() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let times = wordTimes(count: 6, gapSeconds: 0.6, sampleRate: rate)
        let observation = CommandObservation(
            text: "deploy it computer send the message", isFinal: true, wordTimes: times, atOffset: times[5].upperBound)
        let event = onlyAccepted(detector.detect(observation))
        XCTAssertEqual(event?.phraseRange, times[2].lowerBound..<times[5].upperBound)
    }

    func testMissingWordTimingLeavesThePhraseRangeNil() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "computer stop the message", isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertNil(onlyAccepted(detector.detect(observation))?.phraseRange)
    }

    // MARK: - The position gate: nothing spoken after it

    func testAPhraseNotAtTheEndOfTheUtteranceIsRejected() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "computer stop the message please", isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertEqual(
            detector.detect(observation), [.rejected(kind: .stop, reason: .position)],
            "the phrase here is followed by more words, so it is not the last thing said")
    }

    // MARK: - Mid-sentence mentions must never fire — the central false-trigger risk

    func testTalkingAboutComputersMidSentenceNeverFires() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "I was telling my colleague that a computer could start handling this for us",
            isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertEqual(detector.detect(observation), [])
    }

    func testMentioningStopWithoutTheFullPhraseNeverFires() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(text: "we should stop", isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertEqual(detector.detect(observation), [], "\"stop\" alone is not a configured phrase")
    }

    // MARK: - The pause gate: a phrase butting straight up against real speech before it

    /// The actual false-trigger this gate exists for: a phrase that happens to end a sentence
    /// about the command itself, not spoken as one — the position gate alone lets it through.
    func testASentenceEndingOnThePhraseWithNoRealPauseIsRejected() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "the problem is that when I say computer quit the call", isFinal: true,
            wordTimes: wordTimes(count: 11, gapSeconds: 0, sampleRate: rate), atOffset: 1000)
        XCTAssertEqual(detector.detect(observation), [.rejected(kind: .end, reason: .pause)])
    }

    func testAPauseAtLeastAsLongAsTheGateLetsItThrough() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let times = wordTimes(count: 5, gapSeconds: 0.3, sampleRate: rate)
        let observation = CommandObservation(
            text: "wait computer stop the message", isFinal: true, wordTimes: times, atOffset: 1000)
        XCTAssertEqual(onlyAccepted(detector.detect(observation))?.kind, .stop)
    }

    func testAPhraseOpeningTheUtteranceNeedsNoPrecedingPause() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "computer stop the message", isFinal: true,
            wordTimes: wordTimes(count: 4, gapSeconds: 0, sampleRate: rate), atOffset: 1000)
        XCTAssertEqual(onlyAccepted(detector.detect(observation))?.kind, .stop)
    }

    func testMissingWordTimingSkipsThePauseGateRatherThanRefusing() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "please computer stop the message", isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertEqual(
            onlyAccepted(detector.detect(observation))?.kind, .stop,
            "an engine with no timestamps still has the position gate")
    }

    // MARK: - Final-vs-volatile policy

    func testStartDoesNotFireOnAVolatileResult() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "computer start the message", isFinal: false, wordTimes: nil, atOffset: 1000)
        XCTAssertEqual(detector.detect(observation), [.rejected(kind: .start, reason: .notFinal)])
    }

    func testSkipFiresOnAVolatileResult() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "computer skip the message", isFinal: false, wordTimes: nil, atOffset: 1000)
        XCTAssertEqual(
            onlyAccepted(detector.detect(observation))?.kind, .skip, "skip trades false positives for lower latency")
    }

    // MARK: - Dedup across repeated deliveries of the same growing utterance

    func testTheSamePhraseAtTheSameOffsetDoesNotFireTwice() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "computer stop the message", isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertNotNil(onlyAccepted(detector.detect(observation)))
        XCTAssertEqual(detector.detect(observation), [], "a repeated delivery of the same result must not refire")
    }

    func testANewOffsetAfterAFireCanFireAgain() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        _ = detector.detect(
            CommandObservation(text: "computer stop the message", isFinal: true, wordTimes: nil, atOffset: 1000))
        let second = detector.detect(
            CommandObservation(text: "computer skip the message", isFinal: true, wordTimes: nil, atOffset: 2000))
        XCTAssertEqual(onlyAccepted(second)?.kind, .skip)
    }

    // MARK: - Verb inflection and article tolerance

    func testSentTheMessageIsRecognizedAsSend() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "computer sent the message", isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertEqual(onlyAccepted(detector.detect(observation))?.kind, .send)
    }

    func testSendMessageWithNoArticleIsRecognizedAsSend() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "computer send message", isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertEqual(onlyAccepted(detector.detect(observation))?.kind, .send)
    }

    func testSendAMessageIsRecognizedAsSend() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "computer send a message", isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertEqual(onlyAccepted(detector.detect(observation))?.kind, .send)
    }

    func testEndACallIsRecognizedAsEnd() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(text: "computer quit a call", isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertEqual(onlyAccepted(detector.detect(observation))?.kind, .end)
    }

    // MARK: - Custom phrase sets

    func testACustomPhraseSetAtInitIsWhatTheDetectorMatchesAgainst() {
        var phrases = CommandPhraseSet.defaults.phrases
        phrases[.end] = "Jarvis goodbye"
        var detector = CommandDetector(phraseSet: CommandPhraseSet(phrases: phrases), sampleRate: rate)

        let old = detector.detect(
            CommandObservation(text: "computer quit the call", isFinal: true, wordTimes: nil, atOffset: 1000))
        XCTAssertEqual(old, [], "the default phrase should not match once the phrase set overrides it")

        let new = detector.detect(
            CommandObservation(text: "Jarvis goodbye", isFinal: true, wordTimes: nil, atOffset: 2000))
        XCTAssertEqual(onlyAccepted(new)?.kind, .end)
    }

    // MARK: - Interrupt on/off are exempt from the position and pause gates

    /// "Wait, wait. Computer interrupt on. That's so easy." — interrupt is said mid-dictation and
    /// the talking carries on, so neither gate must apply to it.
    func testInterruptOnIsRecognisedMidSentence() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: 16_000)
        let observation = CommandObservation(
            text: "Wait, wait. Computer interrupt on. That's so easy.", isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertEqual(onlyAccepted(detector.detect(observation))?.kind, .interruptOn)
    }

    func testInterruptOffIsRecognisedMidSentence() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: 16_000)
        let observation = CommandObservation(
            text: "Computer interrupt off, that's better now.", isFinal: true, wordTimes: nil, atOffset: 1000)
        XCTAssertEqual(onlyAccepted(detector.detect(observation))?.kind, .interruptOff)
    }

    func testInterruptWithNoPauseAndRealTimingStillFires() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        // No gap at all between "wait" and "computer" — a plain position/pause gate would reject
        // this the same way it rejects a non-exempt command butting up against prior words.
        let times = wordTimes(count: 4, gapSeconds: 0, sampleRate: rate)
        let observation = CommandObservation(
            text: "wait computer interrupt on", isFinal: true, wordTimes: times, atOffset: 1000)
        XCTAssertEqual(onlyAccepted(detector.detect(observation))?.kind, .interruptOn)
    }

    // MARK: - More than one command in a single observation

    /// "computer interrupt off computer send the message" is two commands, not one — the
    /// exempt one must never be lost just because a later, position-gated one shares the
    /// utterance.
    func testTwoCommandsInOneUtteranceAreBothAccepted() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "computer interrupt off computer send the message", isFinal: true, wordTimes: nil, atOffset: 1000)
        let kinds = Set(acceptedEvents(detector.detect(observation)).map(\.kind))
        XCTAssertEqual(kinds, [.interruptOff, .send])
    }

    /// Two non-exempt phrases in one utterance: only the one that actually reaches the end is
    /// accepted, the earlier one rejected for position — same rule as always, now visible in the
    /// full result rather than silently discarded by only ever looking at the last match.
    func testAnEarlierNonExemptPhraseInTheSameUtteranceIsRejectedForPosition() {
        var detector = CommandDetector(phraseSet: .defaults, sampleRate: rate)
        let observation = CommandObservation(
            text: "computer skip the message computer send the message", isFinal: true, wordTimes: nil, atOffset: 1000)
        let outcomes = detector.detect(observation)
        XCTAssertTrue(outcomes.contains(.rejected(kind: .skip, reason: .position)))
        XCTAssertEqual(acceptedEvents(outcomes).map(\.kind), [.send])
    }
}
