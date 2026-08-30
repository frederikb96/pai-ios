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

    // MARK: - Fixture launch-argument seeding

    func testFixtureInitialPathIsEmptyWithoutTheModeFlag() {
        XCTAssertEqual(Router.fixtureInitialPath(arguments: ["/app", "-PaiFixtureRoute", "settings"]), [])
    }

    func testFixtureInitialPathIsEmptyWithModeButNoRoute() {
        XCTAssertEqual(Router.fixtureInitialPath(arguments: ["/app", "-PaiFixtureMode"]), [])
    }

    func testFixtureInitialPathSeedsTheRequestedRoute() {
        let path = Router.fixtureInitialPath(
            arguments: ["/app", "-PaiFixtureMode", "-PaiFixtureRoute", "settings"]
        )
        XCTAssertEqual(path, [.settings])
    }

    func testFixtureInitialPathIsEmptyForAnUnrecognisedRouteName() {
        let path = Router.fixtureInitialPath(
            arguments: ["/app", "-PaiFixtureMode", "-PaiFixtureRoute", "not-a-screen"]
        )
        XCTAssertEqual(path, [])
    }
}

extension RouterTests {

    /// A session deleted while its transcript is open has to take its whole subtree with it. The
    /// reader may well be one level deeper by then — in that session's terminal — and popping a
    /// single route would close the terminal and leave the dead transcript sitting underneath,
    /// still accepting typing for a session the server no longer has.
    @MainActor
    func testDismissingASessionRemovesItsTerminalAlongWithIt() async {
        let router = Router(gate: .ready)
        router.push(.session(id: "a"))
        router.push(.terminal(sessionID: "a"))

        router.dismissSession(id: "a")

        XCTAssertEqual(router.path, [])
    }

    /// Only that session's own screens. Anything beneath it in the stack belongs to somewhere
    /// the reader can still legitimately go back to.
    @MainActor
    func testDismissingASessionLeavesWhatWasUnderneathIt() async {
        let router = Router(gate: .ready)
        router.push(.settings)
        router.push(.session(id: "a"))

        router.dismissSession(id: "a")

        XCTAssertEqual(router.path, [.settings])
    }

    /// Reacting to a session that vanished is not the same as knowing where it was — the screen
    /// may already have been left. Doing nothing beats popping whatever happens to be on top.
    @MainActor
    func testDismissingASessionThatIsNotOnThePathChangesNothing() async {
        let router = Router(gate: .ready)
        router.push(.session(id: "a"))

        router.dismissSession(id: "b")

        XCTAssertEqual(router.path, [.session(id: "a")])
    }
}
