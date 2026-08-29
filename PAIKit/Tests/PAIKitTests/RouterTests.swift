import XCTest

@testable import PAIKit

final class RouterTests: XCTestCase {

    func testOpenSessionIDReadsTheDeepestSessionRatherThanTheFirst() {
        let router = Router(gate: .ready)
        router.push(.session(id: "one"))
        router.push(.settings)
        router.push(.session(id: "two"))

        // Reading forwards would answer "one" — the session the user opened first and has since
        // navigated past — which is what a transcript stream would then subscribe to.
        XCTAssertEqual(router.openSessionID, "two")
    }

    func testTerminalCountsAsHavingItsSessionOpen() {
        let router = Router(gate: .ready)
        router.push(.session(id: "abc"))
        router.push(.terminal(sessionID: "abc"))

        XCTAssertEqual(router.openSessionID, "abc")
    }

    func testSettingsAloneMeansNoSessionIsOpen() {
        let router = Router(gate: .ready)
        router.push(.settings)

        XCTAssertNil(router.openSessionID)
    }

    func testRejectingTheTokenClearsTheStackAsWellAsTheGate() {
        let router = Router(gate: .ready)
        router.push(.session(id: "abc"))

        router.rejectToken()

        XCTAssertEqual(router.gate, .tokenRejected)
        // A path left behind reappears under the recovery screen still showing the transcript it
        // held when the token stopped working.
        XCTAssertTrue(router.path.isEmpty)
    }

    func testPoppingAnEmptyPathIsHarmless() {
        let router = Router(gate: .ready)
        router.pop()
        XCTAssertTrue(router.path.isEmpty)
    }

    func testRoutesToTheSameSessionAreEqualSoTheStackDoesNotGrowOnRepeatedTaps() {
        // NavigationStack dedupes nothing itself; equality is what lets a caller check.
        XCTAssertEqual(Route.session(id: "abc"), Route.session(id: "abc"))
        XCTAssertNotEqual(Route.session(id: "abc"), Route.terminal(sessionID: "abc"))
    }
}
