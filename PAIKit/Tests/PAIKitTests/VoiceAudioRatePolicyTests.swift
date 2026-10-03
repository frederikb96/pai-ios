import XCTest

@testable import PAIKit

final class VoiceAudioRatePolicyTests: XCTestCase {

    func testNarrowbandBoundaryIsExclusive() {
        XCTAssertTrue(VoiceAudioRatePolicy.isNarrowband(rate: 8000))
        XCTAssertTrue(VoiceAudioRatePolicy.isNarrowband(rate: 15999))
        XCTAssertFalse(VoiceAudioRatePolicy.isNarrowband(rate: 16000))
        XCTAssertFalse(VoiceAudioRatePolicy.isNarrowband(rate: 24000))
    }
}
