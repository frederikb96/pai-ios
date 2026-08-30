import Foundation
import XCTest

@testable import PAIKit

/// The decisions that surround a push token, all of which fail silently: a token the backend was
/// never told about looks identical to one it knows, and a store that re-posts on every launch
/// looks identical to one that does not.
@MainActor
final class PushRegistrationStoreTests: XCTestCase {

    private final class Recorder: @unchecked Sendable {
        var tokens: [String] = []
        var shouldThrow = false
        func register(_ token: String) async throws {
            if shouldThrow { throw URLError(.notConnectedToInternet) }
            tokens.append(token)
        }
    }

    private func makeStore(
        storage: SettingsKeyValueStore = SettingsInMemoryKeyValueStore(),
        recorder: Recorder
    ) -> PushRegistrationStore {
        PushRegistrationStore(storage: storage) { try await recorder.register($0) }
    }

    func testAFreshInstallHasAskedForNothing() async {
        let store = makeStore(recorder: Recorder())
        XCTAssertTrue(store.shouldRequestAuthorization)
        XCTAssertEqual(store.registration.status, .notRequested)
    }

    /// The system prompt appears once per install. Re-asking is a silent no-op, so a store that
    /// thinks it can ask again will wait forever for an answer that never comes.
    func testADeniedInstallStopsAsking() async {
        let store = makeStore(recorder: Recorder())
        store.recordAuthorization(granted: false)
        XCTAssertFalse(store.shouldRequestAuthorization)
        XCTAssertEqual(store.registration.status, .denied)
    }

    func testATokenIsSentToTheBackendOnce() async {
        let recorder = Recorder()
        let store = makeStore(recorder: recorder)
        store.recordDeviceToken("abc")

        await store.registerWithBackendIfNeeded()
        await store.registerWithBackendIfNeeded()
        await store.registerWithBackendIfNeeded()

        XCTAssertEqual(recorder.tokens, ["abc"], "an app opened daily must not post the same token daily")
    }

    /// Apple rotates a device token on restore and reinstall. A store keyed on "have I ever
    /// registered" would never notice, and notifications would silently stop arriving.
    func testARotatedTokenIsSentAgain() async {
        let recorder = Recorder()
        let store = makeStore(recorder: recorder)
        store.recordDeviceToken("old")
        await store.registerWithBackendIfNeeded()

        store.recordDeviceToken("new")
        await store.registerWithBackendIfNeeded()

        XCTAssertEqual(recorder.tokens, ["old", "new"])
    }

    /// The common real-world shape: permission granted, token issued, and the device had no
    /// network at that moment. It must still be owed, not quietly considered done.
    func testAFailedRegistrationIsRetriedOnTheNextCall() async {
        let recorder = Recorder()
        recorder.shouldThrow = true
        let store = makeStore(recorder: recorder)
        store.recordDeviceToken("abc")

        await store.registerWithBackendIfNeeded()
        XCTAssertNil(store.registration.registeredToken)
        XCTAssertNotNil(store.registration.lastError)

        recorder.shouldThrow = false
        await store.registerWithBackendIfNeeded()
        XCTAssertEqual(recorder.tokens, ["abc"])
        XCTAssertEqual(store.registration.registeredToken, "abc")
        XCTAssertNil(store.registration.lastError)
    }

    /// What the backend already knows has to outlive the process, or every launch re-posts.
    func testWhatTheBackendKnowsSurvivesARelaunch() async {
        let storage = SettingsInMemoryKeyValueStore()
        let first = Recorder()
        let store = makeStore(storage: storage, recorder: first)
        store.recordDeviceToken("abc")
        await store.registerWithBackendIfNeeded()
        XCTAssertEqual(first.tokens, ["abc"])

        let second = Recorder()
        let relaunched = makeStore(storage: storage, recorder: second)
        await relaunched.registerWithBackendIfNeeded()
        XCTAssertEqual(second.tokens, [], "the token was already acknowledged before the relaunch")
        XCTAssertEqual(relaunched.registration.registeredToken, "abc")
    }

    func testDenialClearsAnyTokenSoNothingIsPostedForADeviceThatCannotReceive() async {
        let recorder = Recorder()
        let store = makeStore(recorder: recorder)
        store.recordDeviceToken("abc")
        store.recordAuthorization(granted: false)

        await store.registerWithBackendIfNeeded()
        XCTAssertEqual(recorder.tokens, [])
    }
}
