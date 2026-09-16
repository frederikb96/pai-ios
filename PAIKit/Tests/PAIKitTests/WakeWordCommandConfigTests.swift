import XCTest
@testable import PAIKit

final class WakeWordManifestTests: XCTestCase {
    func testAnUnlistedCommandFallsBackToTheDefaultThreshold() {
        let manifest = WakeWordManifest(thresholds: ["kai_start": 0.7])
        XCTAssertEqual(manifest.threshold(for: .start), 0.7)
        XCTAssertEqual(manifest.threshold(for: .stop), WakeWordManifest.defaultThreshold)
    }

    func testDecodesFromTheJSONShapeATrainingRunWouldProduce() throws {
        let json = Data(#"{"thresholds":{"kai_start":0.6,"kai_end":0.55}}"#.utf8)
        let manifest = try JSONDecoder().decode(WakeWordManifest.self, from: json)
        XCTAssertEqual(manifest.threshold(for: .start), 0.6)
        XCTAssertEqual(manifest.threshold(for: .end), 0.55)
        XCTAssertEqual(manifest.threshold(for: .skip), WakeWordManifest.defaultThreshold)
    }
}

final class WakeWordListeningConfigTests: XCTestCase {
    func testFullChartListsEveryCommand() {
        XCTAssertEqual(WakeWordListeningConfig.fullChart.offlineCommands, Set(CommandKind.allCases))
    }

    func testStartOnlyFallbackListsOnlyStart() {
        XCTAssertEqual(WakeWordListeningConfig.startOnlyFallback.offlineCommands, [.start])
    }
}

final class WakeWordCommandGateTests: XCTestCase {
    private let rate: Double = 16_000

    func testAScoreAtOrAboveThresholdFires() {
        var gate = WakeWordCommandGate(manifest: WakeWordManifest(thresholds: ["kai_start": 0.5]), sampleRate: rate)
        let events = gate.detect(scores: ["kai_start": 0.6], atOffset: 1000)
        XCTAssertEqual(events.map(\.kind), [.start])
        XCTAssertEqual(events.first?.confidence ?? 0, 0.6, accuracy: 0.0001)
    }

    func testAScoreBelowThresholdIsSilent() {
        var gate = WakeWordCommandGate(manifest: WakeWordManifest(thresholds: ["kai_start": 0.5]), sampleRate: rate)
        XCTAssertTrue(gate.detect(scores: ["kai_start": 0.4], atOffset: 1000).isEmpty)
    }

    func testAnUnrecognisedModelNameIsIgnoredRatherThanCrashing() {
        var gate = WakeWordCommandGate(manifest: WakeWordManifest(), sampleRate: rate)
        XCTAssertTrue(gate.detect(scores: ["not_a_command": 0.99], atOffset: 1000).isEmpty)
    }

    func testMultipleCommandsCrossingThresholdInTheSameRoundAllFire() {
        var gate = WakeWordCommandGate(manifest: WakeWordManifest(), sampleRate: rate)
        let events = gate.detect(scores: ["kai_start": 0.9, "kai_stop": 0.05, "kai_skip": 0.8], atOffset: 1000)
        XCTAssertEqual(Set(events.map(\.kind)), [.start, .skip])
    }

    func testARepeatedHighScoreWithinTheDebounceWindowFiresOnlyOnce() {
        var gate = WakeWordCommandGate(
            manifest: WakeWordManifest(), sampleRate: rate, debounceSeconds: 1.5)
        XCTAssertEqual(gate.detect(scores: ["kai_start": 0.9], atOffset: 0).count, 1)
        // ~20ms later, per WakeWordListener's own predict cadence — well inside the debounce.
        XCTAssertTrue(gate.detect(scores: ["kai_start": 0.9], atOffset: Int(rate * 0.02)).isEmpty)
    }

    func testAScoreCrossingThresholdAgainAfterTheDebounceWindowFiresAgain() {
        var gate = WakeWordCommandGate(
            manifest: WakeWordManifest(), sampleRate: rate, debounceSeconds: 1.5)
        _ = gate.detect(scores: ["kai_start": 0.9], atOffset: 0)
        let secondOffset = Int(rate * 2.0)  // past the 1.5s debounce
        XCTAssertEqual(gate.detect(scores: ["kai_start": 0.9], atOffset: secondOffset).count, 1)
    }

    func testDebounceIsPerCommandNotShared() {
        var gate = WakeWordCommandGate(
            manifest: WakeWordManifest(), sampleRate: rate, debounceSeconds: 1.5)
        _ = gate.detect(scores: ["kai_start": 0.9], atOffset: 0)
        // A different command right after must not be suppressed by start's own debounce window.
        let events = gate.detect(scores: ["kai_stop": 0.9], atOffset: Int(rate * 0.02))
        XCTAssertEqual(events.map(\.kind), [.stop])
    }

    /// This is the gate working exactly as designed — the contract a caller must honor is what
    /// makes it a trap rather than a feature: `atOffset` has to be a genuinely advancing audio
    /// position, never merely repeated. A caller that stalls the offset it feeds this gate (wake
    /// mode's own offset never advancing between collecting cycles, say) reproduces exactly this
    /// shape for a real command spoken a second time, without anything here ever changing.
    func testTwoDetectionsAtTheExactSameOffsetAreDebouncedForever() {
        var gate = WakeWordCommandGate(manifest: WakeWordManifest(), sampleRate: rate)
        let first = gate.detect(scores: ["kai_skip": 0.9], atOffset: 5000)
        let second = gate.detect(scores: ["kai_skip": 0.9], atOffset: 5000)

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 0, "a caller whose offset never advances can never fire this command again")
    }
}
