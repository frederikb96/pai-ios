import XCTest

@testable import PAIKit

/// `Route.named(_:sessionID:)` and `Route.namedScreens` are the launch-argument side of the
/// fixture screenshot workflow — a mismatch between the two (a name in one list the other
/// cannot parse) would leave a screen the workflow discovers but can never actually launch.
final class RouteNamedTests: XCTestCase {

    func testEveryNamedScreenParsesBackToARoute() {
        for name in Route.namedScreens {
            XCTAssertNotNil(Route.named(name, sessionID: "s1"), "\(name) is listed but does not parse")
        }
    }

    func testNamedSessionCarriesTheGivenSessionID() {
        XCTAssertEqual(Route.named("session", sessionID: "abc"), .session(id: "abc"))
    }

    func testNamedTerminalCarriesTheGivenSessionID() {
        XCTAssertEqual(Route.named("terminal", sessionID: "abc"), .terminal(sessionID: "abc"))
    }

    func testNamedSettingsIgnoresTheSessionID() {
        XCTAssertEqual(Route.named("settings", sessionID: "anything"), .settings)
    }

    func testNamedCreateSessionIgnoresTheSessionID() {
        XCTAssertEqual(Route.named("createSession", sessionID: "anything"), .createSession)
    }

    func testNamedRecordingsIgnoresTheSessionID() {
        XCTAssertEqual(Route.named("recordings", sessionID: "anything"), .recordings)
    }

    func testNamedAppsIgnoresTheSessionID() {
        XCTAssertEqual(Route.named("apps", sessionID: "anything"), .apps)
    }

    func testNamedArcSpecListIgnoresTheSessionID() {
        XCTAssertEqual(Route.named("arcSpecList", sessionID: "anything"), .arcSpecList)
    }

    func testUnrecognisedNameParsesToNil() {
        XCTAssertNil(Route.named("not-a-real-screen", sessionID: "s1"))
    }
}
