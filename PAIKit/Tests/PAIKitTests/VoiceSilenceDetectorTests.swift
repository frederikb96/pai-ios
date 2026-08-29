import XCTest

@testable import PAIKit

/// `SilenceDetector` is a pure state machine driven by injected `elapsedMs`, so every case here
/// is a synthetic sample sequence rather than a real microphone or a real sleep — the risk this
/// guards against is a refactor silently changing when a take auto-stops (too early loses words,
/// too late defeats the point of the feature).
final class VoiceSilenceDetectorTests: XCTestCase {

    private func config(
        enabled: Bool = true, threshold: Double = 0.01, durationMs: Int = 1000, graceMs: Int = 0,
        emaAlpha: Double = 1.0
    ) -> SilenceDetectorConfig {
        .init(enabled: enabled, thresholdRms: threshold, durationMs: durationMs, graceMs: graceMs, emaAlpha: emaAlpha)
    }

    func testFiresOnceQuietHasPersistedForTheFullDuration() {
        var detector = SilenceDetector(config: config(durationMs: 1000))
        XCTAssertFalse(detector.observe(rms: 0.001, elapsedMs: 0, muted: false))
        XCTAssertFalse(detector.observe(rms: 0.001, elapsedMs: 500, muted: false))
        XCTAssertFalse(detector.observe(rms: 0.001, elapsedMs: 999, muted: false))
        XCTAssertTrue(detector.observe(rms: 0.001, elapsedMs: 1000, muted: false))
    }

    /// A loud sample partway through a quiet stretch must restart the clock, not merely pause
    /// it — otherwise a brief word followed by a pause could trigger off the pause that preceded
    /// it rather than a genuinely continuous silence.
    func testALoudSampleResetsTheQuietTimer() {
        var detector = SilenceDetector(config: config(durationMs: 1000))
        XCTAssertFalse(detector.observe(rms: 0.001, elapsedMs: 0, muted: false))
        XCTAssertFalse(detector.observe(rms: 0.001, elapsedMs: 900, muted: false))
        // Loud again just before the old timer would have fired.
        XCTAssertFalse(detector.observe(rms: 0.5, elapsedMs: 950, muted: false))
        // Quiet resumes at 1900 — the timer restarts from here, so it needs a full extra
        // 1000ms from *this* sample, not from the original run that started at 0.
        XCTAssertFalse(detector.observe(rms: 0.001, elapsedMs: 1900, muted: false))
        XCTAssertFalse(detector.observe(rms: 0.001, elapsedMs: 2899, muted: false))
        XCTAssertTrue(detector.observe(rms: 0.001, elapsedMs: 2900, muted: false))
    }

    func testGracePeriodSuppressesFiringEvenWhenAlreadyQuiet() {
        var detector = SilenceDetector(config: config(durationMs: 1000, graceMs: 3000))
        // Quiet for the entire grace period — must not fire during it.
        XCTAssertFalse(detector.observe(rms: 0.001, elapsedMs: 0, muted: false))
        XCTAssertFalse(detector.observe(rms: 0.001, elapsedMs: 2999, muted: false))
        // Quiet timer only starts counting once grace ends, so it needs a full extra
        // `durationMs` from that point rather than firing the instant grace ends.
        XCTAssertFalse(detector.observe(rms: 0.001, elapsedMs: 3000, muted: false))
        XCTAssertFalse(detector.observe(rms: 0.001, elapsedMs: 3999, muted: false))
        XCTAssertTrue(detector.observe(rms: 0.001, elapsedMs: 4000, muted: false))
    }

    /// A muted mic reads as silence and must never end a recording — the one behaviour both the
    /// web and Android agree on despite their otherwise opposite semantics.
    func testMutedSuspendsDetectionEvenThoughAmplitudeIsBelowThreshold() {
        var detector = SilenceDetector(config: config(durationMs: 1000))
        XCTAssertFalse(detector.observe(rms: 0.0, elapsedMs: 0, muted: true))
        XCTAssertFalse(detector.observe(rms: 0.0, elapsedMs: 1000, muted: true))
        XCTAssertFalse(detector.observe(rms: 0.0, elapsedMs: 2000, muted: true))
    }

    func testDisabledNeverFiresRegardlessOfHowLongItIsQuiet() {
        var detector = SilenceDetector(config: config(enabled: false, durationMs: 1000))
        XCTAssertFalse(detector.observe(rms: 0.0, elapsedMs: 0, muted: false))
        XCTAssertFalse(detector.observe(rms: 0.0, elapsedMs: 10000, muted: false))
    }

    /// Once fired, a detector must not fire again for the same take even if the caller keeps
    /// feeding it quiet samples — the caller (the session) is expected to have stopped the
    /// recording by then, but a second `true` would double-trigger a stop if it did not.
    func testFiresOnlyOncePerTake() {
        var detector = SilenceDetector(config: config(durationMs: 1000))
        XCTAssertFalse(detector.observe(rms: 0.0, elapsedMs: 0, muted: false))
        XCTAssertTrue(detector.observe(rms: 0.0, elapsedMs: 1000, muted: false))
        XCTAssertFalse(detector.observe(rms: 0.0, elapsedMs: 2000, muted: false))
        XCTAssertFalse(detector.observe(rms: 0.0, elapsedMs: 5000, muted: false))
    }

    /// EMA smoothing means a single quiet sample sandwiched between loud ones does not itself
    /// read as below threshold — this is the behaviour Android's `0.3*rms + 0.7*smoothed`
    /// exists to produce, and `emaAlpha: 1.0` (used by every other test here) would fail this
    /// one, which is what proves the smoothing path is actually reachable.
    func testSmoothingKeepsATransientDipFromReadingAsQuiet() {
        var detector = SilenceDetector(config: config(threshold: 0.1, durationMs: 500, emaAlpha: 0.3))
        // Loud enough that a single near-zero dip should not pull the smoothed value under
        // threshold on its own.
        XCTAssertFalse(detector.observe(rms: 0.5, elapsedMs: 0, muted: false))
        XCTAssertFalse(detector.observe(rms: 0.5, elapsedMs: 100, muted: false))
        XCTAssertFalse(detector.observe(rms: 0.0, elapsedMs: 200, muted: false))
        // Loud again immediately after — the transient dip must not have reset the loud state
        // into a quiet one.
        XCTAssertFalse(detector.observe(rms: 0.5, elapsedMs: 300, muted: false))
    }
}
