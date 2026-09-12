import XCTest

@testable import PAIKit

final class VoiceReconnectPolicyTests: XCTestCase {

    func testBackoffFollowsThePortedAndroidSchedule() {
        XCTAssertEqual(ReconnectPolicy.delaySeconds(forAttempt: 1), 5)
        XCTAssertEqual(ReconnectPolicy.delaySeconds(forAttempt: 2), 10)
        XCTAssertEqual(ReconnectPolicy.delaySeconds(forAttempt: 3), 20)
    }

    /// Attempts past the schedule's length reuse the last delay rather than crashing on an
    /// out-of-bounds index — a plausible refactor mistake since the schedule (3 entries) and
    /// `maxAttempts` (5) do not agree in length.
    func testAttemptsBeyondScheduleLengthReuseTheLastDelay() {
        XCTAssertEqual(ReconnectPolicy.delaySeconds(forAttempt: 4), 20)
        XCTAssertEqual(ReconnectPolicy.delaySeconds(forAttempt: 5), 20)
    }

    func testNoDelayPastMaxAttempts() {
        XCTAssertNil(ReconnectPolicy.delaySeconds(forAttempt: 6))
    }
}
