import XCTest

@testable import PAIKit

/// Exercises the argument parsing on plain `[String]` input rather than the live process's own
/// `ProcessInfo.arguments` — the default parameter reads that, but nothing here can control it,
/// so every test injects its own array instead.
final class PaiFixtureLaunchTests: XCTestCase {

    func testIsEnabledIsTrueOnlyWhenTheModeFlagIsPresent() {
        XCTAssertTrue(PaiFixtureLaunch.isEnabled(arguments: ["/path/to/app", "-PaiFixtureMode"]))
        XCTAssertFalse(PaiFixtureLaunch.isEnabled(arguments: ["/path/to/app"]))
    }

    func testRequestedRouteNameReadsTheValueFollowingTheFlag() {
        let name = PaiFixtureLaunch.requestedRouteName(
            arguments: ["/path/to/app", "-PaiFixtureMode", "-PaiFixtureRoute", "settings"]
        )
        XCTAssertEqual(name, "settings")
    }

    func testRequestedRouteNameIsNilWhenTheFlagIsAbsent() {
        XCTAssertNil(PaiFixtureLaunch.requestedRouteName(arguments: ["/path/to/app", "-PaiFixtureMode"]))
    }

    /// A flag with nothing after it (a malformed launch, or truncated at the array's end) must
    /// not read past the array — the naive `index(after:)` here is exactly where that would
    /// crash if the bounds check were dropped.
    func testRequestedRouteNameIsNilWhenTheFlagIsLastWithNoValue() {
        XCTAssertNil(PaiFixtureLaunch.requestedRouteName(arguments: ["/path/to/app", "-PaiFixtureRoute"]))
    }

    func testFlagOrderDoesNotMatter() {
        let name = PaiFixtureLaunch.requestedRouteName(
            arguments: ["/path/to/app", "-PaiFixtureRoute", "terminal", "-PaiFixtureMode"]
        )
        XCTAssertEqual(name, "terminal")
        XCTAssertTrue(PaiFixtureLaunch.isEnabled(arguments: ["-PaiFixtureRoute", "terminal", "-PaiFixtureMode"]))
    }
}
