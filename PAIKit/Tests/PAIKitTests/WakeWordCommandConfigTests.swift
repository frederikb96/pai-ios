import XCTest
@testable import PAIKit

final class WakeWordManifestTests: XCTestCase {
    func testAnEmptyManifestFallsBackToTheDefaultThreshold() {
        let manifest = WakeWordManifest()
        XCTAssertEqual(manifest.threshold, WakeWordManifest.defaultThreshold)
    }

    func testDecodesFromTheJSONShapeATrainingRunWouldProduce() throws {
        let json = Data(#"{"thresholds":{"computer":0.62}}"#.utf8)
        let manifest = try JSONDecoder().decode(WakeWordManifest.self, from: json)
        XCTAssertEqual(manifest.threshold, 0.62, accuracy: 0.0001)
    }
}

final class WakeWordDetectionGateTests: XCTestCase {
    private let rate: Double = 16_000

    func testAScoreAtOrAboveThresholdFires() {
        var gate = WakeWordDetectionGate(manifest: WakeWordManifest(thresholds: ["computer": 0.5]), sampleRate: rate)
        let event = gate.detect(score: 0.6, atOffset: 1000)
        XCTAssertEqual(event?.kind, .start)
        XCTAssertEqual(event?.confidence ?? 0, 0.6, accuracy: 0.0001)
    }

    func testAScoreBelowThresholdIsSilent() {
        var gate = WakeWordDetectionGate(manifest: WakeWordManifest(thresholds: ["computer": 0.5]), sampleRate: rate)
        XCTAssertNil(gate.detect(score: 0.4, atOffset: 1000))
    }

    func testARepeatedHighScoreWithinTheDebounceWindowFiresOnlyOnce() {
        var gate = WakeWordDetectionGate(manifest: WakeWordManifest(), sampleRate: rate, debounceSeconds: 1.5)
        XCTAssertNotNil(gate.detect(score: 0.9, atOffset: 0))
        // ~20ms later, per the listener's own predict cadence — well inside the debounce.
        XCTAssertNil(gate.detect(score: 0.9, atOffset: Int(rate * 0.02)))
    }

    func testAScoreCrossingThresholdAgainAfterTheDebounceWindowFiresAgain() {
        var gate = WakeWordDetectionGate(manifest: WakeWordManifest(), sampleRate: rate, debounceSeconds: 1.5)
        _ = gate.detect(score: 0.9, atOffset: 0)
        let secondOffset = Int(rate * 2.0)  // past the 1.5s debounce
        XCTAssertNotNil(gate.detect(score: 0.9, atOffset: secondOffset))
    }

    /// This is the gate working exactly as designed — the contract a caller must honor is what
    /// makes it a trap rather than a feature: `atOffset` has to be a genuinely advancing audio
    /// position, never merely repeated. A caller that stalls the offset it feeds this gate (wake
    /// mode's own offset never advancing between collecting cycles, say) reproduces exactly this
    /// shape for a real wake word spoken a second time, without anything here ever changing.
    func testTwoDetectionsAtTheExactSameOffsetAreDebouncedForever() {
        var gate = WakeWordDetectionGate(manifest: WakeWordManifest(), sampleRate: rate)
        let first = gate.detect(score: 0.9, atOffset: 5000)
        let second = gate.detect(score: 0.9, atOffset: 5000)

        XCTAssertNotNil(first)
        XCTAssertNil(second, "a caller whose offset never advances can never fire again")
    }
}
