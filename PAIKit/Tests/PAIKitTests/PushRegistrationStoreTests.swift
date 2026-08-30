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
        var mutedChannels: [[PushChannel]] = []
        var shouldThrow = false
        /// Stands in for the backend normalising what it stores. Returning something other than
        /// what was sent is the case that matters: the store must remember the answer, not the
        /// question.
        var normalise: (String) -> String = { $0 }
        /// What the backend says it holds. `nil` stands in for one that does not answer about
        /// channels at all, which is not the same as one answering "nothing is muted".
        var answersMutedChannels: ([PushChannel]) -> [String]? = { $0.map(\.rawValue) }

        func register(_ token: String, _ muted: [PushChannel]) async throws -> DeviceRegistration {
            if shouldThrow { throw URLError(.notConnectedToInternet) }
            tokens.append(token)
            mutedChannels.append(muted)
            return DeviceRegistration(
                token: normalise(token), registered: true, lastSeenAt: nil,
                mutedChannels: answersMutedChannels(muted))
        }
    }

    private func makeStore(
        storage: SettingsKeyValueStore = SettingsInMemoryKeyValueStore(),
        recorder: Recorder
    ) -> PushRegistrationStore {
        PushRegistrationStore(storage: storage) { try await recorder.register($0, $1) }
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

    /// The backend stores its own normalised form. Remembering what was SENT rather than what
    /// came back would leave the two disagreeing, and the store would re-post on every launch
    /// forever with nothing actually wrong.
    func testTheStoreRemembersWhatTheBackendConfirmedNotWhatItSent() async {
        let recorder = Recorder()
        recorder.normalise = { $0.uppercased() }
        let store = makeStore(recorder: recorder)
        store.recordDeviceToken("abc")

        await store.registerWithBackendIfNeeded()
        XCTAssertEqual(store.registration.registeredToken, "ABC")
    }

    /// A toggle flipped is a change the backend has to hear about, and the token has not moved —
    /// so a store that decides purely on the token would record the choice locally, show it as
    /// set, and never send it.
    func testFlippingAChannelPostsAgainEvenThoughTheTokenIsUnchanged() async {
        let recorder = Recorder()
        let store = makeStore(recorder: recorder)
        store.recordDeviceToken("abc")
        await store.registerWithBackendIfNeeded()

        await store.setMuted(true, for: .alerts)

        XCTAssertEqual(recorder.tokens, ["abc", "abc"])
        XCTAssertEqual(recorder.mutedChannels, [[], [.alerts]])
    }

    /// Flipping a channel back to where it already was is not a change, and posting for it would
    /// put the register call back on every redraw of a settings screen.
    func testSettingAChannelToWhatItAlreadyIsPostsNothing() async {
        let recorder = Recorder()
        let store = makeStore(recorder: recorder)
        store.recordDeviceToken("abc")
        await store.registerWithBackendIfNeeded()

        await store.setMuted(false, for: .alerts)

        XCTAssertEqual(recorder.tokens, ["abc"])
    }

    /// A toggle flipped with no network must stay flipped AND stay owed. Losing either half is a
    /// setting that silently does not apply.
    func testAChannelFlippedOfflineIsKeptAndStillOwed() async {
        let recorder = Recorder()
        let store = makeStore(recorder: recorder)
        store.recordDeviceToken("abc")
        await store.registerWithBackendIfNeeded()

        recorder.shouldThrow = true
        await store.setMuted(true, for: .default)
        XCTAssertTrue(store.registration.isMuted(.default), "the toggle has to stay where it was put")
        XCTAssertTrue(store.registration.needsBackendRegistration)

        recorder.shouldThrow = false
        await store.registerWithBackendIfNeeded()
        XCTAssertEqual(recorder.mutedChannels, [[], [.default]])
        XCTAssertFalse(store.registration.needsBackendRegistration)
    }

    /// A backend too old to know about channels stores what it was given and says nothing about
    /// it. Reading that silence as "nothing is muted" would leave the client believing the two
    /// disagree, and re-posting on every launch forever.
    func testABackendThatSaysNothingAboutChannelsIsNotReadAsSayingNoneAreMuted() async {
        let recorder = Recorder()
        recorder.answersMutedChannels = { _ in nil }
        let store = makeStore(recorder: recorder)
        store.recordDeviceToken("abc")
        await store.setMuted(true, for: .alerts)
        XCTAssertFalse(store.registration.needsBackendRegistration)

        await store.registerWithBackendIfNeeded()
        XCTAssertEqual(recorder.tokens, ["abc"], "one post, not one per call")
    }

    /// Channel choices have to outlive the process for the same reason the token does.
    func testChannelChoicesSurviveARelaunch() async {
        let storage = SettingsInMemoryKeyValueStore()
        let first = Recorder()
        let store = makeStore(storage: storage, recorder: first)
        store.recordDeviceToken("abc")
        await store.setMuted(true, for: .alerts)

        let second = Recorder()
        let relaunched = makeStore(storage: storage, recorder: second)
        XCTAssertTrue(relaunched.registration.isMuted(.alerts))
        await relaunched.registerWithBackendIfNeeded()
        XCTAssertEqual(second.tokens, [], "already acknowledged before the relaunch")
    }

}
