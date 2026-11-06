import XCTest

@testable import PAIKit

/// Hermes is the emergency engine: it must stay startable while Claude is signed out, and it is
/// not an API session (it keeps the ordinary composer, files and model picker).
@MainActor
final class HermesSessionTypeTests: XCTestCase {
    private func makeStore() -> CreateSessionStore {
        CreateSessionStore(machines: MachineStore(api: FakeMachineDirectoryApi()), api: FakeCreateSessionApi())
    }

    private func auth(loggedIn: Bool?) -> ClaudeAuth {
        ClaudeAuth(
            known: true, loggedIn: loggedIn, health: nil, subscription: nil,
            accessExpiresAt: nil, refreshExpiresAt: nil, login: nil, lastError: nil, reportedAt: nil)
    }

    func testHermesStartsWhileSignedOutButOrdinaryTypesDoNot() async {
        let store = makeStore()
        let signedOut = auth(loggedIn: false)

        store.selectSessionType("hermes")
        XCTAssertTrue(store.isHermesSelected)
        XCTAssertFalse(store.isApiSessionSelected)
        XCTAssertFalse(store.signInBlocksStart(signedOut))

        store.selectSessionType("home")
        XCTAssertTrue(store.signInBlocksStart(signedOut))
        XCTAssertFalse(store.signInBlocksStart(auth(loggedIn: true)))

        store.selectSessionType("ultrafast")
        XCTAssertFalse(store.signInBlocksStart(signedOut))
    }
}
