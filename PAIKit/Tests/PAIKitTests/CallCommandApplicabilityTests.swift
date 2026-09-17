import XCTest
@testable import PAIKit

final class CallCommandApplicabilityTests: XCTestCase {
    func testStartIsApplicableWhileASendIsStillInFlight() {
        XCTAssertTrue(CallCommandApplicability.isApplicable(.start, phase: .sending, hasReplyAudio: false))
    }

    func testStartIsNotApplicableWhileCollecting() {
        XCTAssertFalse(
            CallCommandApplicability.isApplicable(.start, phase: .collecting(startOffset: 0), hasReplyAudio: false))
    }

    func testStopIsOnlyApplicableWhileCollecting() {
        XCTAssertTrue(
            CallCommandApplicability.isApplicable(.stop, phase: .collecting(startOffset: 0), hasReplyAudio: false))
        XCTAssertFalse(CallCommandApplicability.isApplicable(.stop, phase: .listening, hasReplyAudio: false))
        XCTAssertFalse(CallCommandApplicability.isApplicable(.stop, phase: .sending, hasReplyAudio: false))
    }

    func testSkipRequiresReplyAudio() {
        XCTAssertTrue(CallCommandApplicability.isApplicable(.skip, phase: .listening, hasReplyAudio: true))
        XCTAssertFalse(CallCommandApplicability.isApplicable(.skip, phase: .listening, hasReplyAudio: false))
    }

    func testEndIsAlwaysApplicable() {
        for phase: CallModePhase in [.idle, .entering, .listening, .collecting(startOffset: 0), .sending, .pendingSend]
        {
            XCTAssertTrue(CallCommandApplicability.isApplicable(.end, phase: phase, hasReplyAudio: false))
        }
    }
}
