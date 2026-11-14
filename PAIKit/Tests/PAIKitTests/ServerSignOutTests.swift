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

    func testTheCurrentSignInIsEnded() async {
        let calls = Calls()
        await ServerSignOut(signOutCurrentSignIn: { calls.add("sign-out") }).run(timeout: 5)
        XCTAssertEqual(calls.all, ["sign-out"])
    }

    /// A backend that predates the route answers 404; the phone signs out regardless.
    func testAFailingServerStillReturns() async {
        let signOut = ServerSignOut(signOutCurrentSignIn: { throw PaiError.http(statusCode: 404, reason: "Not Found") })
        await signOut.run(timeout: 5)
    }

    /// Offline, a request can hang until the system gives up; sign-out must not wait for it.
    func testAHangingServerDoesNotHoldSignOutBeyondTheTimeout() async {
        let signOut = ServerSignOut(signOutCurrentSignIn: { try await Task.sleep(nanoseconds: 60_000_000_000) })
        let started = Date()
        await signOut.run(timeout: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testSigningOutPostsToTheCurrentSignInRoute() async throws {
        let factory = try PaiRequestFactory(
            baseURL: "https://pai.example.com", deviceName: "Test iPhone", tokenProvider: { "jwt" })
        let client = PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
        PaiStubURLProtocol.stub = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"],
            body: Data(#"{"id":"abc","kind":"app","active":false,"current":true}"#.utf8))
        try await client.signOutCurrentSignIn()
        let request = try XCTUnwrap(PaiStubURLProtocol.capturedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/sign-ins/current/sign-out")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Name"), "Test iPhone")
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
