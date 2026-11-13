import XCTest

@testable import PAIKit

private struct FakeMeApi: MeApiClient {
    let role: UserRole
    func getMe() async throws -> MeResponse {
        MeResponse(identity: "x", role: role, allowedSessionIds: [])
    }
}

private actor CountingMeApi: MeApiClient {
    private(set) var requestCount = 0

    func getMe() async throws -> MeResponse {
        requestCount += 1
        try await Task.sleep(nanoseconds: 50_000_000)
        return MeResponse(identity: "x", role: .guest, allowedSessionIds: [])
    }
}

@MainActor
final class MeStoreTests: XCTestCase {

    /// Hiding the owner's screens from a guest must not hide them from the owner while the
    /// identity check is still on its way.
    func testNobodyIsAGuestUntilTheIdentityAnswers() async {
        let store = MeStore(api: FakeMeApi(role: .guest))
        XCTAssertFalse(store.isGuest)

        await store.refresh()

        XCTAssertTrue(store.isGuest)
    }

    func testTheOwnerIsNotAGuest() async {
        let store = MeStore(api: FakeMeApi(role: .owner))
        await store.refresh()
        XCTAssertFalse(store.isGuest)
        XCTAssertTrue(store.isOwner)
    }

    func testCapabilitiesAreUnknownUntilTheIdentityAnswers() async {
        let store = MeStore(api: FakeMeApi(role: .guest))
        XCTAssertEqual(store.capabilities, .unknown)

        await store.refresh()

        XCTAssertEqual(store.capabilities, Capabilities(role: .guest))
        XCTAssertFalse(store.capabilities.canOpenNotes)
    }

    /// Startup and the push registration both need the identity; they must not ask twice.
    func testOverlappingReadsShareOneRequest() async {
        let api = CountingMeApi()
        let store = MeStore(api: api)

        async let first: Void = store.refresh()
        async let second: Void = store.ensureKnown()
        _ = await (first, second)

        let requests = await api.requestCount
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(store.capabilities.isKnown)
    }
}
