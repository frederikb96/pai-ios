import XCTest

@testable import PAIKit

/// `SilenceDetector` is a pure state machine driven by injected `elapsedMs`, so every case here
/// is a synthetic sample sequence rather than a real microphone or a real sleep — the risk this
/// guards against is a refactor silently changing when a take gates, resumes or ends (too early
/// loses words, too late defeats the point of the feature).
final class VoiceSilenceDetectorTests: XCTestCase {

    private func config(
        enabled: Bool = true, threshold: Double = 0.01, durationMs: Int = 1000, graceMs: Int = 0,
        maxGatedMs: Int = 120_000, emaAlpha: Double = 1.0
    ) -> SilenceDetectorConfig {
        .init(
            enabled: enabled, thresholdRms: threshold, durationMs: durationMs, graceMs: graceMs,
            maxGatedMs: maxGatedMs, emaAlpha: emaAlpha)
    }

    func testGatesOnceQuietHasPersistedForTheFullDuration() {
        var detector = SilenceDetector(config: config(durationMs: 1000))
        XCTAssertEqual(detector.observe(rms: 0.001, elapsedMs: 0, muted: false), .none)
        XCTAssertEqual(detector.observe(rms: 0.001, elapsedMs: 500, muted: false), .none)
        XCTAssertEqual(detector.observe(rms: 0.001, elapsedMs: 999, muted: false), .none)
        XCTAssertEqual(detector.observe(rms: 0.001, elapsedMs: 1000, muted: false), .gate)
    }

    /// A loud sample partway through a quiet stretch must restart the clock, not merely pause
    /// it — otherwise a brief word followed by a pause could trigger off the pause that preceded
    /// it rather than a genuinely continuous silence.
    func testALoudSampleResetsTheQuietTimer() {
        var detector = SilenceDetector(config: config(durationMs: 1000))
        XCTAssertEqual(detector.observe(rms: 0.001, elapsedMs: 0, muted: false), .none)
        XCTAssertEqual(detector.observe(rms: 0.001, elapsedMs: 900, muted: false), .none)
        // Loud again just before the old timer would have fired.
        XCTAssertEqual(detector.observe(rms: 0.5, elapsedMs: 950, muted: false), .none)
        // Quiet resumes at 1900 — the timer restarts from here, so it needs a full extra
        // 1000ms from *this* sample, not from the original run that started at 0.
        XCTAssertEqual(detector.observe(rms: 0.001, elapsedMs: 1900, muted: false), .none)
        XCTAssertEqual(detector.observe(rms: 0.001, elapsedMs: 2899, muted: false), .none)
        XCTAssertEqual(detector.observe(rms: 0.001, elapsedMs: 2900, muted: false), .gate)
    }

    func testGracePeriodSuppressesGatingEvenWhenAlreadyQuiet() {
        var detector = SilenceDetector(config: config(durationMs: 1000, graceMs: 3000))
        // Quiet for the entire grace period — must not gate during it.
        XCTAssertEqual(detector.observe(rms: 0.001, elapsedMs: 0, muted: false), .none)
        XCTAssertEqual(detector.observe(rms: 0.001, elapsedMs: 2999, muted: false), .none)
        // Quiet timer only starts counting once grace ends, so it needs a full extra
        // `durationMs` from that point rather than gating the instant grace ends.
        XCTAssertEqual(detector.observe(rms: 0.001, elapsedMs: 3000, muted: false), .none)
        XCTAssertEqual(detector.observe(rms: 0.001, elapsedMs: 3999, muted: false), .none)
        XCTAssertEqual(detector.observe(rms: 0.001, elapsedMs: 4000, muted: false), .gate)
    }

    /// A muted mic reads as silence and must never gate a recording — the one behaviour both the
    /// web and Android agree on despite their otherwise opposite semantics.
    func testMutedSuspendsDetectionEvenThoughAmplitudeIsBelowThreshold() {
        var detector = SilenceDetector(config: config(durationMs: 1000))
        XCTAssertEqual(detector.observe(rms: 0.0, elapsedMs: 0, muted: true), .none)
        XCTAssertEqual(detector.observe(rms: 0.0, elapsedMs: 1000, muted: true), .none)
        XCTAssertEqual(detector.observe(rms: 0.0, elapsedMs: 2000, muted: true), .none)
    }

    func testDisabledNeverGatesRegardlessOfHowLongItIsQuiet() {
        var detector = SilenceDetector(config: config(enabled: false, durationMs: 1000))
        XCTAssertEqual(detector.observe(rms: 0.0, elapsedMs: 0, muted: false), .none)
        XCTAssertEqual(detector.observe(rms: 0.0, elapsedMs: 10000, muted: false), .none)
    }

    /// The regression this guards: silence used to auto-stop a take outright. It must now gate
    /// the audio off and resume on its own once speech returns, over and over across one take —
    /// a take with two separate pauses gates twice, not just once.
    func testGatesAgainAfterResuming() {
        var detector = SilenceDetector(config: config(durationMs: 1000))
        XCTAssertEqual(detector.observe(rms: 0.0, elapsedMs: 0, muted: false), .none)
        XCTAssertEqual(detector.observe(rms: 0.0, elapsedMs: 1000, muted: false), .gate)
        // Still quiet -- no repeated `.gate` while already gated.
        XCTAssertEqual(detector.observe(rms: 0.0, elapsedMs: 2000, muted: false), .none)
        // Speech resumes -- immediate, no sustained duration required, unlike gating.
        XCTAssertEqual(detector.observe(rms: 0.5, elapsedMs: 2100, muted: false), .resume)
        // A second, unrelated run of quiet gates again.
        XCTAssertEqual(detector.observe(rms: 0.0, elapsedMs: 2200, muted: false), .none)
        XCTAssertEqual(detector.observe(rms: 0.0, elapsedMs: 3199, muted: false), .none)
        XCTAssertEqual(detector.observe(rms: 0.0, elapsedMs: 3200, muted: false), .gate)
    }

    /// A gate that never lifts must still end the take, or this is an open, silent socket for as
    /// long as nobody notices.
    func testBackstopStopsATakeThatStaysGatedForTooLong() {
        var detector = SilenceDetector(config: config(durationMs: 1000, maxGatedMs: 5000))
        XCTAssertEqual(detector.observe(rms: 0.0, elapsedMs: 0, muted: false), .none)
        XCTAssertEqual(detector.observe(rms: 0.0, elapsedMs: 1000, muted: false), .gate)
        XCTAssertEqual(detector.observe(rms: 0.0, elapsedMs: 3000, muted: false), .none)
        XCTAssertEqual(detector.observe(rms: 0.0, elapsedMs: 5999, muted: false), .none)
        XCTAssertEqual(detector.observe(rms: 0.0, elapsedMs: 6000, muted: false), .stop)
    }

    /// Hand-muting while gated must suspend the backstop's own clock too, not just the ordinary
    /// quiet timer — someone who mutes to take a call during a gated stretch comes back to a
    /// recording still going, whatever the call's own length.
    func testMutingWhileGatedSuspendsTheBackstopClock() {
        var detector = SilenceDetector(config: config(durationMs: 1000, maxGatedMs: 5000))
        XCTAssertEqual(detector.observe(rms: 0.0, elapsedMs: 0, muted: false), .none)
        XCTAssertEqual(detector.observe(rms: 0.0, elapsedMs: 1000, muted: false), .gate)
        // Muted for far longer than `maxGatedMs` -- must never fire the backstop while muted.
        for elapsed in stride(from: 2000, through: 20_000, by: 2000) {
            XCTAssertEqual(detector.observe(rms: 0.0, elapsedMs: elapsed, muted: true), .none)
        }
        // Unmuted and still quiet: the backstop counts from the last muted sample (20,000 --
        // effectively "now" at the moment muting ends, since a real caller feeds this every
        // 100-200ms), not from the original gate at 1,000.
        XCTAssertEqual(detector.observe(rms: 0.0, elapsedMs: 21_000, muted: false), .none)
        XCTAssertEqual(detector.observe(rms: 0.0, elapsedMs: 24_999, muted: false), .none)
        XCTAssertEqual(detector.observe(rms: 0.0, elapsedMs: 25_000, muted: false), .stop)
    }

    /// EMA smoothing means a single quiet sample sandwiched between loud ones does not itself
    /// read as below threshold — this is the behaviour Android's `0.3*rms + 0.7*smoothed`
    /// exists to produce, and `emaAlpha: 1.0` (used by every other test here) would fail this
    /// one, which is what proves the smoothing path is actually reachable.
    func testSmoothingKeepsATransientDipFromReadingAsQuiet() {
        var detector = SilenceDetector(config: config(threshold: 0.1, durationMs: 500, emaAlpha: 0.3))
        // Loud enough that a single near-zero dip should not pull the smoothed value under
        // threshold on its own.
        XCTAssertEqual(detector.observe(rms: 0.5, elapsedMs: 0, muted: false), .none)
        XCTAssertEqual(detector.observe(rms: 0.5, elapsedMs: 100, muted: false), .none)
        XCTAssertEqual(detector.observe(rms: 0.0, elapsedMs: 200, muted: false), .none)
        // Loud again immediately after — the transient dip must not have reset the loud state
        // into a quiet one.
        XCTAssertEqual(detector.observe(rms: 0.5, elapsedMs: 300, muted: false), .none)
    }
}
