import XCTest

@testable import PAIKit

final class ComposerCallMenuTests: XCTestCase {
    func testNoCallRunningOffersToStart() {
        XCTAssertEqual(
            ComposerCallMenu.state(callBoundSessionID: nil, sessionID: "session-a"), .start)
    }

    func testCallBoundToThisSessionOffersToReturn() {
        XCTAssertEqual(
            ComposerCallMenu.state(callBoundSessionID: "session-a", sessionID: "session-a"), .returnToCall)
    }

    func testCallBoundToAnotherSessionOffersToSwitch() {
        XCTAssertEqual(
            ComposerCallMenu.state(callBoundSessionID: "session-a", sessionID: "session-b"), .runningElsewhere)
    }
}

final class VoiceHandoverTests: XCTestCase {

    // MARK: - Microphone tap

    func testMicrophoneTapWithNothingRunningStartsOnly() {
        XCTAssertEqual(
            VoiceHandover.forMicrophoneTap(
                sessionID: "session-a", microphoneTakeSessionID: nil, callModeActive: false),
            .startOnly)
    }

    func testMicrophoneTapWhileItsOwnTakeIsRunningIsNotAHandover() {
        XCTAssertEqual(
            VoiceHandover.forMicrophoneTap(
                sessionID: "session-a", microphoneTakeSessionID: "session-a", callModeActive: false),
            .alreadyHere)
    }

    func testMicrophoneTapStopsATakeRunningInAnotherSession() {
        XCTAssertEqual(
            VoiceHandover.forMicrophoneTap(
                sessionID: "session-b", microphoneTakeSessionID: "session-a", callModeActive: false),
            .stopMicrophoneTake(sessionID: "session-a"))
    }

    /// Call mode wins over a microphone-mode reading of the running take: the two never overlap
    /// in practice (the shared microphone enforces that), but a caller building this from stale
    /// state must still get the right instruction rather than a contradictory one.
    func testMicrophoneTapStopsCallModeEvenIfATakeSessionIDIsAlsoReported() {
        XCTAssertEqual(
            VoiceHandover.forMicrophoneTap(
                sessionID: "session-b", microphoneTakeSessionID: "session-a", callModeActive: true),
            .stopCallMode)
    }

    // MARK: - Starting call mode

    func testCallModeStartWithNothingRunningStartsOnly() {
        XCTAssertEqual(
            VoiceHandover.forCallModeStart(
                sessionID: "session-a", callBoundSessionID: nil, microphoneTakeSessionID: nil),
            .startOnly)
    }

    func testCallModeStartWhenAlreadyBoundToThisSessionIsNotAHandover() {
        XCTAssertEqual(
            VoiceHandover.forCallModeStart(
                sessionID: "session-a", callBoundSessionID: "session-a", microphoneTakeSessionID: nil),
            .alreadyHere)
    }

    func testCallModeStartStopsACallBoundToAnotherSession() {
        XCTAssertEqual(
            VoiceHandover.forCallModeStart(
                sessionID: "session-b", callBoundSessionID: "session-a", microphoneTakeSessionID: nil),
            .stopCallMode)
    }

    func testCallModeStartStopsAMicrophoneTakeWhenNoCallIsRunning() {
        XCTAssertEqual(
            VoiceHandover.forCallModeStart(
                sessionID: "session-b", callBoundSessionID: nil, microphoneTakeSessionID: "session-a"),
            .stopMicrophoneTake(sessionID: "session-a"))
    }
}
