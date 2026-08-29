import XCTest

@testable import PAIKit

/// `transportRate` encodes two rules that are easy to accidentally invert in a refactor: never
/// raise the rate (upsampling invents samples), and never exceed 24 kHz (wasted bandwidth,
/// nothing the model uses). Each test targets one direction so a regression in either shows up
/// on its own rather than being masked by the other.
final class VoiceAudioRatePolicyTests: XCTestCase {

    func testNeverExceeds24kHzEvenWhenHardwareIsFaster() {
        XCTAssertEqual(VoiceAudioRatePolicy.transportRate(hardwareRate: 48000), 24000)
        XCTAssertEqual(VoiceAudioRatePolicy.transportRate(hardwareRate: 96000), 24000)
    }

    func testNeverRaisesTheRateAboveHardwareWhenHardwareIsSlower() {
        // 11025 is below every supported rate above 8000, so it must snap down to 8000 rather
        // than up to 16000 — upsampling here would invent samples the hardware never produced.
        XCTAssertEqual(VoiceAudioRatePolicy.transportRate(hardwareRate: 11025), 8000)
    }

    func testExactlySupportedRateIsPassedThroughUnchanged() {
        XCTAssertEqual(VoiceAudioRatePolicy.transportRate(hardwareRate: 16000), 16000)
        XCTAssertEqual(VoiceAudioRatePolicy.transportRate(hardwareRate: 22050), 22050)
    }

    func testHardwareBelowEverySupportedRateFallsBackToTheLowest() {
        XCTAssertEqual(VoiceAudioRatePolicy.transportRate(hardwareRate: 4000), 8000)
    }

    func testNarrowbandBoundaryIsExclusive() {
        XCTAssertTrue(VoiceAudioRatePolicy.isNarrowband(rate: 8000))
        XCTAssertTrue(VoiceAudioRatePolicy.isNarrowband(rate: 15999))
        XCTAssertFalse(VoiceAudioRatePolicy.isNarrowband(rate: 16000))
        XCTAssertFalse(VoiceAudioRatePolicy.isNarrowband(rate: 24000))
    }
}
