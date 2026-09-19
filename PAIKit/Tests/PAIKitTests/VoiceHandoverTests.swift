import XCTest

@testable import PAIKit

final class VoiceHandoverTests: XCTestCase {
    func testMicrophoneTapWithNothingRunningStartsOnly() {
        XCTAssertEqual(
            VoiceHandover.forMicrophoneTap(sessionID: "session-a", microphoneTakeSessionID: nil), .startOnly)
    }

    func testMicrophoneTapWhileItsOwnTakeIsRunningIsNotAHandover() {
        XCTAssertEqual(
            VoiceHandover.forMicrophoneTap(sessionID: "session-a", microphoneTakeSessionID: "session-a"),
            .alreadyHere)
    }

    func testMicrophoneTapStopsATakeRunningInAnotherSession() {
        XCTAssertEqual(
            VoiceHandover.forMicrophoneTap(sessionID: "session-b", microphoneTakeSessionID: "session-a"),
            .stopMicrophoneTake(sessionID: "session-a"))
    }
}
