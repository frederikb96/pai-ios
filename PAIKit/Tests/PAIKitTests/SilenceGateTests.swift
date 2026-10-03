import XCTest

@testable import PAIKit

/// The shared vectors every client's gate is held to (web `silenceGate.test.ts`, pai-stt
/// `test_silence_gate.py`): 100 ms frames at 16 kHz, auto mode unless noted. A divergence between
/// the three implementations shows up here as a red vector rather than as two clients that
/// withhold differently.
///
/// After V1 the floor sits near −75 dBFS, but the open threshold is clamped at −60 (it is never
/// set below that), so close is −63 and the loud-onset level −50 — which is what V3 and V4 sit
/// either side of.
final class SilenceGateTests: XCTestCase {
    private static let frameSamples = 1600

    /// A frame whose RMS sits at `db` dBFS (to the nearest integer sample value).
    private static func samples(db: Double) -> [Int16] {
        let amplitude = Int16((32768 * pow(10, db / 20)).rounded())
        return (0..<frameSamples).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
    }

    private struct Run {
        var gate: SilenceGate
        var offset = 0
        var sent: [SilenceGate.Frame] = []
        var silenceAt: [Int] = []

        init(_ settings: SilenceGateSettings = .standard) {
            gate = SilenceGate(settings: settings)
            _ = gate.setAllowed(true)
        }

        mutating func feed(db: Double, count: Int) {
            for _ in 0..<count {
                let output = gate.push(offset: offset, samples: SilenceGateTests.samples(db: db))
                sent += output.send
                if let at = output.silenceAt { silenceAt.append(at) }
                offset += SilenceGateTests.frameSamples
            }
        }

        mutating func apply(_ output: SilenceGate.Output) {
            sent += output.send
            if let at = output.silenceAt { silenceAt.append(at) }
        }
    }

    /// V1 — speech then room tone: withholds once five seconds of quiet sit under a floor that
    /// has settled below −50, sending the frame that completes the window first.
    func testV1QuietAfterSpeechWithholdsAtEightSeconds() {
        var run = Run()
        run.feed(db: -40, count: 30)
        // The first ~3 s of quiet: quiet time grows, but the floor still includes the speech and
        // sits above −50, so nothing is withheld yet.
        run.feed(db: -75, count: 30)
        XCTAssertFalse(run.gate.isWithholding)
        XCTAssertTrue(run.silenceAt.isEmpty)

        run.feed(db: -75, count: 30)
        XCTAssertEqual(run.silenceAt, [128_000])
        XCTAssertEqual(run.sent.last?.endOffset, 128_000)
        XCTAssertEqual(run.sent.count, 80, "frames from 8.0 s on are withheld")
        XCTAssertTrue(run.gate.isWithholding)
    }

    /// V2 — speech after the withheld stretch. The first loud frame is ≥ open + 10 dB, so it
    /// resumes at once and the ring — the last full second, ending with that frame — goes out
    /// with its true offsets, nothing before `at_sample` resent.
    func testV2SpeechAfterWithholdingSendsTheLastSecondFirst() {
        var run = Run()
        run.feed(db: -40, count: 30)
        run.feed(db: -75, count: 90)
        let sentBefore = run.sent.count
        run.feed(db: -40, count: 1)

        XCTAssertFalse(run.gate.isWithholding)
        let resumed = Array(run.sent[sentBefore...])
        XCTAssertEqual(resumed.count, 10)
        XCTAssertEqual(resumed.first?.offset, 177_600)
        XCTAssertEqual(resumed.last?.endOffset, 193_600)
        XCTAssertTrue(resumed.allSatisfy { $0.offset >= 128_000 })

        run.feed(db: -40, count: 1)
        XCTAssertEqual(run.sent.last?.offset, 193_600, "streaming again after the ring")
    }

    /// V3 — one frame above open but short of the loud-onset margin, then quiet again: not
    /// enough onset to resume.
    func testV3BriefNoiseBelowOnsetDoesNotResume() {
        var run = Run()
        run.feed(db: -40, count: 30)
        run.feed(db: -75, count: 60)
        let sentBefore = run.sent.count
        run.feed(db: -56, count: 1)
        run.feed(db: -75, count: 5)
        XCTAssertTrue(run.gate.isWithholding)
        XCTAssertEqual(run.sent.count, sentBefore)
    }

    /// V4 — one frame ≥ open + 10 dB resumes immediately.
    func testV4LoudFrameResumesImmediately() {
        var run = Run()
        run.feed(db: -40, count: 30)
        run.feed(db: -75, count: 60)
        XCTAssertTrue(run.gate.isWithholding)
        run.feed(db: -48, count: 1)
        XCTAssertFalse(run.gate.isWithholding)
    }

    /// V5 — manual −45: withholds after five seconds under the close threshold, resumes after
    /// 150 ms above open.
    func testV5ManualThreshold() {
        var run = Run(SilenceGateSettings(enabled: true, mode: .manual, manualThresholdDb: -45))
        run.feed(db: -50, count: 60)
        XCTAssertEqual(run.silenceAt, [80_000])
        run.feed(db: -44, count: 1)
        XCTAssertTrue(run.gate.isWithholding, "100 ms above open is not an onset yet")
        run.feed(db: -44, count: 1)
        XCTAssertFalse(run.gate.isWithholding)
    }

    /// V6 — a loud room (floor above −50) never withholds in auto mode.
    func testV6LoudRoomNeverWithholds() {
        var run = Run()
        run.feed(db: -45, count: 150)
        XCTAssertTrue(run.silenceAt.isEmpty)
        XCTAssertEqual(run.sent.count, 150)
    }

    /// V7 — the backend withdrawing permission resumes at once and sends the ring.
    func testV7DisallowedResumesAndSendsTheRing() {
        var run = Run()
        run.feed(db: -40, count: 30)
        run.feed(db: -75, count: 70)
        let sentBefore = run.sent.count
        run.apply(run.gate.setAllowed(false))
        XCTAssertFalse(run.gate.isWithholding)
        XCTAssertEqual(run.sent.count - sentBefore, 10)
        XCTAssertEqual(run.sent.last?.endOffset, 160_000)
    }

    /// V8 — once acks reach where withholding began, every captured frame older than the
    /// pre-roll ring counts as accounted for; the ring itself is still to be sent on resume, so
    /// it is never claimed. Before the ack reaches the start, the watermark is left alone.
    func testV8WithheldAudioIsAccountedOnceTheAckReachesTheStart() {
        var run = Run()
        run.feed(db: -40, count: 30)
        run.feed(db: -75, count: 50)
        run.feed(db: -75, count: 3)
        XCTAssertEqual(run.gate.accountedWatermark(acked: 120_000, capturedUpTo: run.offset), 120_000)
        XCTAssertEqual(run.gate.accountedWatermark(acked: 128_000, capturedUpTo: run.offset), 128_000)

        // Twenty withheld frames: the ring keeps the last ten, so only what precedes them is settled.
        run.feed(db: -75, count: 17)
        XCTAssertEqual(run.offset, 160_000)
        XCTAssertEqual(run.gate.accountedWatermark(acked: 128_000, capturedUpTo: run.offset), 144_000)
    }

    /// Stop while withholding with nothing above open in the ring: nothing is sent.
    func testStopWhileWithholdingQuietSendsNothing() {
        var run = Run()
        run.feed(db: -40, count: 30)
        run.feed(db: -75, count: 60)
        XCTAssertTrue(run.gate.stopFlush().isEmpty)
    }

    /// The gate off never withholds, however quiet.
    func testDisabledNeverWithholds() {
        var run = Run(SilenceGateSettings(enabled: false, mode: .auto, manualThresholdDb: -45))
        run.feed(db: -40, count: 30)
        run.feed(db: -100, count: 100)
        XCTAssertTrue(run.silenceAt.isEmpty)
    }
}
