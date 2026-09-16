import XCTest

@testable import PAIKit

/// Built from a real device log's actual scores — two genuine co-fire clusters, one entirely
/// within a single `WakeWordCommandGate.detect(scores:atOffset:)` round and one spread across two
/// rounds about 100ms apart at the call's own 24kHz transport rate.
final class WakeWordCommandArbiterTests: XCTestCase {
    private let rate: Double = 24_000

    func testASingleDetectionStillFiresOnceItsWindowElapses() {
        var arbiter = WakeWordCommandArbiter(sampleRate: rate)
        let event = CommandEvent(kind: .start, atOffset: 1000, confidence: 0.7)
        XCTAssertNil(arbiter.observe(newEvents: [event], atOffset: 1000))
        let windowSamples = Int(rate * WakeWordCommandArbiter.defaultWindowSeconds)
        let winner = arbiter.observe(newEvents: [], atOffset: 1000 + windowSamples)
        XCTAssertEqual(winner, event)
    }

    /// "start" 0.61 and "stop" 0.54, both detected in the same round at offset 1454152 — the
    /// higher-confidence "start" is what actually reached the call in the log.
    func testTwoCommandsCoFiringInTheSameRoundPicksTheHigherConfidenceOne() {
        var arbiter = WakeWordCommandArbiter(sampleRate: rate)
        let start = CommandEvent(kind: .start, atOffset: 1_454_152, confidence: 0.61)
        let stop = CommandEvent(kind: .stop, atOffset: 1_454_152, confidence: 0.54)
        XCTAssertNil(arbiter.observe(newEvents: [start, stop], atOffset: 1_454_152))

        let windowSamples = Int(rate * WakeWordCommandArbiter.defaultWindowSeconds)
        let winner = arbiter.observe(newEvents: [], atOffset: 1_454_152 + windowSamples)
        XCTAssertEqual(winner?.kind, .start)
        XCTAssertEqual(winner?.confidence ?? 0, 0.61, accuracy: 0.0001)
    }

    /// "end" 0.58 and "skip" 0.50 at offset 3882952, then "send" 0.53, "start" 0.62 and "stop"
    /// 0.65 about 100ms later (offset 3885368) — five detections for one spoken command, spread
    /// across two prediction rounds. "stop" has the highest confidence of all five and must be
    /// the only one delivered.
    func testFiveCommandsCoFiringAcrossTwoRoundsPicksTheSingleHighestScoring() {
        var arbiter = WakeWordCommandArbiter(sampleRate: rate)
        let firstRound = [
            CommandEvent(kind: .end, atOffset: 3_882_952, confidence: 0.58),
            CommandEvent(kind: .skip, atOffset: 3_882_952, confidence: 0.50),
        ]
        XCTAssertNil(arbiter.observe(newEvents: firstRound, atOffset: 3_882_952))

        let secondRound = [
            CommandEvent(kind: .send, atOffset: 3_885_368, confidence: 0.53),
            CommandEvent(kind: .start, atOffset: 3_885_368, confidence: 0.62),
            CommandEvent(kind: .stop, atOffset: 3_885_368, confidence: 0.65),
        ]
        XCTAssertNil(
            arbiter.observe(newEvents: secondRound, atOffset: 3_885_368),
            "still within the window the first round opened — must not release early")

        let windowSamples = Int(rate * WakeWordCommandArbiter.defaultWindowSeconds)
        let winner = arbiter.observe(newEvents: [], atOffset: 3_882_952 + windowSamples)
        XCTAssertEqual(winner?.kind, .stop)
        XCTAssertEqual(winner?.confidence ?? 0, 0.65, accuracy: 0.0001)
    }

    func testNoDetectionsEverProducesNoWinner() {
        var arbiter = WakeWordCommandArbiter(sampleRate: rate)
        for offset in stride(from: 0, to: 100_000, by: 2_000) {
            XCTAssertNil(arbiter.observe(newEvents: [], atOffset: offset))
        }
    }

    /// Two genuinely separate commands, seconds apart, must each fire on their own — the window
    /// exists to fold a burst, not to merge everything a whole cycle ever hears.
    func testTwoCommandsSecondsApartEachFireSeparately() {
        var arbiter = WakeWordCommandArbiter(sampleRate: rate)
        let windowSamples = Int(rate * WakeWordCommandArbiter.defaultWindowSeconds)
        let start = CommandEvent(kind: .start, atOffset: 0, confidence: 0.9)
        XCTAssertNil(arbiter.observe(newEvents: [start], atOffset: 0))
        let firstWinner = arbiter.observe(newEvents: [], atOffset: windowSamples)
        XCTAssertEqual(firstWinner?.kind, .start)

        let skip = CommandEvent(kind: .skip, atOffset: Int(rate * 3), confidence: 0.9)
        XCTAssertNil(arbiter.observe(newEvents: [skip], atOffset: Int(rate * 3)))
        let secondWinner = arbiter.observe(newEvents: [], atOffset: Int(rate * 3) + windowSamples)
        XCTAssertEqual(secondWinner?.kind, .skip)
    }
}
