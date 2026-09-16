import XCTest

@testable import PAIKit

final class VoiceReconnectPolicyTests: XCTestCase {

    func testBackoffGrowsThroughTheSchedule() {
        XCTAssertEqual(ReconnectPolicy.delaySeconds(forAttempt: 1), 2)
        XCTAssertEqual(ReconnectPolicy.delaySeconds(forAttempt: 2), 4)
        XCTAssertEqual(ReconnectPolicy.delaySeconds(forAttempt: 3), 8)
        XCTAssertEqual(ReconnectPolicy.delaySeconds(forAttempt: 4), 16)
        XCTAssertEqual(ReconnectPolicy.delaySeconds(forAttempt: 5), 30)
    }

    /// No attempt limit: an attempt count past the schedule's own length must keep returning the
    /// ceiling delay forever rather than running out — the ported Android policy this replaces
    /// gave up after five; this one never does.
    func testAttemptsFarBeyondTheScheduleStillReturnTheCeilingDelay() {
        XCTAssertEqual(ReconnectPolicy.delaySeconds(forAttempt: 6), 30)
        XCTAssertEqual(ReconnectPolicy.delaySeconds(forAttempt: 1000), 30)
    }

    func testAttemptZeroOrNegativeIsTreatedAsTheFirstAttempt() {
        XCTAssertEqual(ReconnectPolicy.delaySeconds(forAttempt: 0), 2)
        XCTAssertEqual(ReconnectPolicy.delaySeconds(forAttempt: -1), 2)
    }
}
