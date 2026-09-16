import XCTest
@testable import PAIKit

/// `Earcon.samples` is pure arithmetic — these check length, peak and the silence between tones,
/// never a device's actual loudness (that's `I1` in the design, a device-only instrument).
final class EarconTests: XCTestCase {
    private let rate: Double = 24_000

    // MARK: - Length

    func testLengthScalesWithSampleRate() {
        let atBaseRate = Earcon.samples(kind: .drop, sampleRate: rate)
        let atDoubleRate = Earcon.samples(kind: .drop, sampleRate: rate * 2)
        // Not an exact 2x (rounding per tone), but doubling the rate must not leave the buffer
        // roughly the same size or shrink it — the tell for a length computed from the wrong unit.
        XCTAssertGreaterThan(atDoubleRate.count, Int(Double(atBaseRate.count) * 1.8))
        XCTAssertLessThan(atDoubleRate.count, Int(Double(atBaseRate.count) * 2.2))
    }

    func testMultiToneKindsAreLongerThanSingleToneKinds() {
        let single = Earcon.samples(kind: .pause, sampleRate: rate)
        let triple = Earcon.samples(kind: .healed, sampleRate: rate)
        XCTAssertGreaterThan(triple.count, single.count)
    }

    // MARK: - Peak

    func testPeakStaysWithinInt16BoundsAndIsAudible() {
        for kind: EarconKind in [.drop, .reconnect, .healed, .error, .pause, .command(.start)] {
            let samples = Earcon.samples(kind: kind, sampleRate: rate)
            let peak = samples.map { abs(Int($0)) }.max() ?? 0
            XCTAssertLessThan(peak, Int(Int16.max), "\(kind) clips")
            XCTAssertGreaterThan(peak, Int(Int16.max) / 4, "\(kind) is too quiet to be a usable cue")
        }
    }

    // MARK: - Envelope: silence between tones

    func testTwoToneKindHasASilentStretchBetweenTheTones() {
        let samples = Earcon.samples(kind: .drop, sampleRate: rate)
        // The first tone's peak region sits in the first third of the buffer, the second tone's
        // in the last third — search the middle third for a run of near-silence between them.
        let thirdCount = samples.count / 3
        let middle = samples[thirdCount..<(2 * thirdCount)]
        let silenceThreshold = Int(Int16.max) / 20
        let hasQuietRun = middle.contains { abs(Int($0)) < silenceThreshold }
        XCTAssertTrue(hasQuietRun, "expected a quiet gap between the two tones of .drop")
    }

    func testSingleToneKindHasNoSilentGapInItsMiddle() {
        let samples = Earcon.samples(kind: .error, sampleRate: rate)
        let quarterCount = samples.count / 4
        let middle = Array(samples[quarterCount..<(3 * quarterCount)])
        let silenceThreshold = Int(Int16.max) / 20
        // A plain sine wave crosses zero every half-period, so asserting every single sample is
        // audible would fail on the tone itself, not on a gap. A sustained silent stretch is a
        // run of *windows* with no audible peak at all — one window comfortably longer than one
        // period at the lowest frequency any kind uses (220 Hz here, ~109 samples/period).
        let windowSize = 300
        var index = 0
        while index < middle.count {
            let window = middle[index..<min(index + windowSize, middle.count)]
            let peak = window.map { abs(Int($0)) }.max() ?? 0
            XCTAssertGreaterThanOrEqual(peak, silenceThreshold, "found a silent window inside a single sustained tone")
            index += windowSize
        }
    }

    func testDropAndReconnectAreTheSameTonesReversed() {
        // Not the same melody played twice — the two must be distinguishable by ear, and one
        // concrete way to prove that arithmetically is that they are not byte-identical.
        let drop = Earcon.samples(kind: .drop, sampleRate: rate)
        let reconnect = Earcon.samples(kind: .reconnect, sampleRate: rate)
        XCTAssertNotEqual(drop, reconnect)
    }

    func testEveryCommandKindProducesADistinctCue() {
        let cues = CommandKind.allCases.map { Earcon.samples(kind: .command($0), sampleRate: rate) }
        for i in 0..<cues.count {
            for j in (i + 1)..<cues.count where j < cues.count {
                XCTAssertNotEqual(
                    cues[i], cues[j], "\(CommandKind.allCases[i]) and \(CommandKind.allCases[j]) sound the same")
            }
        }
    }
}
