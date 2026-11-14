import Foundation
import XCTest

@testable import PAIKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }
    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

final class ServerSignOutTests: XCTestCase {

    override func tearDown() {
        PaiStubURLProtocol.reset()
        super.tearDown()
    }

    func testTheCurrentSignInIsRevoked() async {
        let calls = Calls()
        let signOut = ServerSignOut(
            currentSignInId: { "sign-in-1" }, revokeSignIn: { calls.add("revoke \($0)") })
        await signOut.run(timeout: 5)
        XCTAssertEqual(calls.all, ["revoke sign-in-1"])
    }

    func testNoCurrentSignInRevokesNothing() async {
        let calls = Calls()
        let signOut = ServerSignOut(currentSignInId: { nil }, revokeSignIn: { calls.add("revoke \($0)") })
        await signOut.run(timeout: 5)
        XCTAssertEqual(calls.all, [])
    }

    /// Offline, a request can hang until the system gives up; sign-out must not wait for it.
    func testAHangingServerDoesNotHoldSignOutBeyondTheTimeout() async {
        let signOut = ServerSignOut(
            currentSignInId: {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return nil
            },
            revokeSignIn: { _ in })
        let started = Date()
        await signOut.run(timeout: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testSignInsAreListedAndRevokedThroughTheSignInsRoutes() async throws {
        let factory = try PaiRequestFactory(
            baseURL: "https://pai.example.com", deviceName: "Test iPhone", tokenProvider: { "jwt" })
        let client = PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
        let row = """
            {"id":"abc","kind":"app","name":"iPhone","client_id":null,"user_id":null,"display_name":null,
            "user_agent":null,"first_seen_at":"2026-01-01T00:00:00Z","last_seen_at":"2026-01-01T00:00:00Z",
            "revoked_at":null,"active":true,"current":true,"agent_slug":null}
            """
        PaiStubURLProtocol.stub = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"], body: Data("[\(row)]".utf8))
        let signIns = try await client.listSignIns()
        XCTAssertEqual(signIns.first { $0.current }?.id, "abc")
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.url?.path, "/api/sign-ins")

        PaiStubURLProtocol.stub = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(row.utf8))
        try await client.revokeSignIn(id: "abc")
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.url?.path, "/api/sign-ins/abc/revoke")
    }

    @MainActor
    func testForgettingTheBackendRegistrationMakesTheNextLaunchRegisterAgain() async {
        let store = PushRegistrationStore(
            storage: SettingsInMemoryKeyValueStore(), isRegistrationAllowed: { true },
            registerToken: { token, _ in
                DeviceRegistration(token: token, registered: true, lastSeenAt: nil, mutedChannels: [])
            })
        store.recordDeviceToken("abcd")
        await store.registerWithBackendIfNeeded()
        XCTAssertFalse(store.registration.needsBackendRegistration)

        store.forgetBackendRegistration()
        XCTAssertTrue(store.registration.needsBackendRegistration)
        XCTAssertEqual(store.registration.deviceToken, "abcd")
    }
}
