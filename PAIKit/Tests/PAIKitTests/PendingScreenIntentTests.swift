import XCTest

@testable import PAIKit

/// These two signals arm something a reader did not ask for in the moment it happens — a live
/// microphone, a raised keyboard. Their whole value is that they fire exactly once, and the way
/// they break is silent: a screen that reappears (a rotation, a return from the photo picker, a
/// restored navigation path on a cold launch) would re-arm, and a microphone that starts on its
/// own looks like the app misbehaving rather than like a stale flag.
@MainActor
final class PendingScreenIntentTests: XCTestCase {

    func testACallRequestIsConsumedOnce() async {
        let request = CallModeLaunchRequest()
        XCTAssertFalse(request.consume(), "a fresh request must not claim to have been armed")

        request.arm()
        XCTAssertTrue(request.consume())
        XCTAssertFalse(request.consume(), "a second appearance of the same screen must not re-arm")
    }

    /// A screen that was abandoned has to be able to put the request back, or the *next* new
    /// session inherits it — a call nobody asked for, started from a different tile entirely.
    func testACancelledCallRequestIsNotConsumed() async {
        let request = CallModeLaunchRequest()
        request.arm()
        request.cancel()
        XCTAssertFalse(request.consume())
    }

    /// Keyed by session id, because the composer that consumes it is one of many and each one
    /// asks on mount. Answering yes to the wrong session would open a call on a conversation
    /// nobody was starting.
    func testAnOpenCallRequestOnlyAnswersForItsOwnSession() async {
        let request = CallModeLaunchRequest()
        request.openCall(forSession: "session-a")

        XCTAssertFalse(request.consumeOpenCall(forSession: "session-b"))
        XCTAssertTrue(
            request.consumeOpenCall(forSession: "session-a"),
            "asking on behalf of another session must not consume the request")
        XCTAssertFalse(request.consumeOpenCall(forSession: "session-a"), "returning later must not reopen it")
    }

    /// The two signals share an object but not a lifetime: the microphone flag is cleared by the
    /// screen that used it, long before the session it leads to exists.
    func testConsumingTheMicrophoneFlagLeavesAnOpenCallRequestStanding() async {
        let request = CallModeLaunchRequest()
        request.arm()
        request.openCall(forSession: "session-a")

        XCTAssertTrue(request.consume())
        XCTAssertTrue(request.consumeOpenCall(forSession: "session-a"))
    }

    func testAFilterFocusRequestIsConsumedOnce() async {
        let focus = NotesFilterFocus()
        XCTAssertFalse(focus.consume())

        focus.arm()
        XCTAssertTrue(focus.consume())
        XCTAssertFalse(focus.consume())
    }
}
