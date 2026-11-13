import XCTest

@testable import PAIKit

final class CapabilitiesTests: XCTestCase {

    private func ownerOnlyQuestions(_ capabilities: Capabilities) -> [Bool] {
        [
            capabilities.canOpenNotes, capabilities.canOpenArc, capabilities.canOpenScheduler,
            capabilities.canOpenCanteen, capabilities.canOpenDecisions, capabilities.canOpenBrowser,
            capabilities.canReadSecrets, capabilities.canRegisterPush,
        ]
    }

    func testTheOwnerMayReachEverything() {
        XCTAssertEqual(ownerOnlyQuestions(Capabilities(role: .owner)), Array(repeating: true, count: 8))
    }

    /// The guest is the case the type exists for: none of the owner's routes, which would each
    /// answer 403.
    func testAGuestMayReachNothingOwnerOnly() {
        let guest = Capabilities(role: .guest)
        XCTAssertTrue(guest.isKnown)
        XCTAssertEqual(ownerOnlyQuestions(guest), Array(repeating: false, count: 8))
    }

    /// Until `/api/me` has answered, and for a role this build predates, nothing owner-only is
    /// offered or requested.
    func testUnknownAndUnrecognizedRolesMayReachNothingOwnerOnly() {
        XCTAssertFalse(Capabilities.unknown.isKnown)
        XCTAssertEqual(ownerOnlyQuestions(.unknown), Array(repeating: false, count: 8))
        let unrecognized = Capabilities(role: .unrecognized("admin"))
        XCTAssertTrue(unrecognized.isKnown)
        XCTAssertEqual(ownerOnlyQuestions(unrecognized), Array(repeating: false, count: 8))
    }

    func testCapabilitiesComeFromTheMeResponse() {
        let me = MeResponse(identity: "x", role: .guest, allowedSessionIds: [])
        XCTAssertEqual(Capabilities(me: me), Capabilities(role: .guest))
        XCTAssertEqual(Capabilities(me: nil), .unknown)
    }
}
