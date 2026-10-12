import XCTest

@testable import PAIKit

private struct FakeMeApi: MeApiClient {
    let role: UserRole
    func getMe() async throws -> MeResponse {
        MeResponse(identity: "x", role: role, allowedSessionIds: [])
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
}
