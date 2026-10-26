import XCTest

@testable import PAIKit

/// A session that stops being drivable replaces its composer with a reason — unless a take of its
/// own is still running or owed, whose controls live in that composer and must outlast the session.
final class SessionComposerReplacementTests: XCTestCase {

    private func moved() -> Session {
        var session = SessionFixture.make(state: .closed)
        session.transferredToSessionId = "elsewhere"
        return session
    }

    func testClosedSessionReplacesComposerWithoutATake() {
        XCTAssertTrue(
            SessionListDomain.replacesComposer(SessionFixture.make(state: .closed), ownsTake: false))
    }

    func testMovedSessionReplacesComposerWithoutATake() {
        XCTAssertTrue(SessionListDomain.replacesComposer(moved(), ownsTake: false))
    }

    func testClosedSessionKeepsComposerWhileItOwnsATake() {
        XCTAssertFalse(
            SessionListDomain.replacesComposer(SessionFixture.make(state: .closed), ownsTake: true))
    }

    func testMovedSessionKeepsComposerWhileItOwnsATake() {
        XCTAssertFalse(SessionListDomain.replacesComposer(moved(), ownsTake: true))
    }

    func testDrivableSessionNeverReplacesComposer() {
        let session = SessionFixture.make(state: .ready)
        XCTAssertFalse(SessionListDomain.replacesComposer(session, ownsTake: false))
        XCTAssertFalse(SessionListDomain.replacesComposer(session, ownsTake: true))
    }
}
