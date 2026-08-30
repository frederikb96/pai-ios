import Foundation
import XCTest

@testable import PAIKit

/// The half of push registration that can be got wrong silently. Both properties covered here
/// fail without producing an error anywhere: a mis-encoded token registers successfully and
/// simply never receives anything, and a wrong "needs registering" rule either never tells the
/// backend about a rotated token or POSTs on every launch forever.
final class PushRegistrationTests: XCTestCase {

    // MARK: - Token encoding

    /// The expectation is a literal, not something derived from the implementation's own format
    /// string, so a change to how the bytes are rendered has to justify itself here.
    func testHexTokenRendersEveryByteAsTwoLowercaseDigits() {
        let data = Data([0x00, 0x0f, 0x10, 0xab, 0xff])
        XCTAssertEqual(PushRegistration.hexToken(from: data), "000f10abff")
    }

    /// The specific mistake this guards: `%x` instead of `%02x` drops the leading zero on any
    /// byte below 0x10, which shortens the token without making it look wrong. A real APNs token
    /// is 32 bytes, and roughly two of them are below 0x10 on average, so the result is a
    /// plausible hex string of the wrong length that APNs rejects as an unknown device.
    func testHexTokenKeepsLeadingZeroesSoLengthIsAlwaysTwicePerByte() {
        let data = Data([UInt8](repeating: 0x07, count: 32))
        let hex = PushRegistration.hexToken(from: data)
        XCTAssertEqual(hex.count, 64)
        XCTAssertEqual(hex, String(repeating: "07", count: 32))
    }

    func testHexTokenOfEmptyDataIsEmpty() {
        XCTAssertEqual(PushRegistration.hexToken(from: Data()), "")
    }

    // MARK: - When the backend needs telling

    func testNoTokenMeansNothingToRegister() {
        XCTAssertFalse(PushRegistration(status: .authorized).needsBackendRegistration)
    }

    func testEmptyTokenIsTreatedAsNoToken() {
        let state = PushRegistration(status: .authorized, deviceToken: "")
        XCTAssertFalse(state.needsBackendRegistration)
    }

    func testAFreshTokenNeedsRegistering() {
        let state = PushRegistration(status: .authorized, deviceToken: "abc123")
        XCTAssertTrue(state.needsBackendRegistration)
    }

    /// The case that distinguishes a real rule from one that only checks "have I ever
    /// registered": Apple rotates a device token on restore and reinstall, and a rule keyed on
    /// "registeredToken is not nil" would never notice.
    func testARotatedTokenNeedsRegisteringAgain() {
        let state = PushRegistration(
            status: .authorized, deviceToken: "new", registeredToken: "old")
        XCTAssertTrue(state.needsBackendRegistration)
    }

    /// And the other half of that rule: once they agree, an app launched every day must not POST
    /// every day.
    func testAnAcknowledgedTokenNeedsNothing() {
        let state = PushRegistration(
            status: .authorized, deviceToken: "same", registeredToken: "same",
            registeredMutedChannels: [])
        XCTAssertFalse(state.needsBackendRegistration)
    }

    /// A registration carried over from a build that had no channels knows a token the backend
    /// acknowledged and nothing about what it holds for the channels. That is not the same as
    /// knowing it holds none, and posting once to find out is the only way the two ever agree.
    func testARegistrationThatPredatesChannelsPostsOnce() {
        let state = PushRegistration(
            status: .authorized, deviceToken: "same", registeredToken: "same")
        XCTAssertTrue(state.needsBackendRegistration)
    }

    /// A muted channel the backend has not been told about is a setting that silently does
    /// nothing — the phone shows it off and every notification still arrives.
    func testAMuteTheBackendHasNotAcknowledgedIsStillOwed() {
        let state = PushRegistration(
            status: .authorized, deviceToken: "same", registeredToken: "same",
            mutedChannels: [.alerts], registeredMutedChannels: [])
        XCTAssertTrue(state.needsBackendRegistration)
    }

    // MARK: - When asking is still possible

    func testAuthorizationIsOnlyWorthRequestingBeforeTheOneShotPromptIsAnswered() {
        XCTAssertTrue(PushRegistration(status: .notRequested).canRequestAuthorization)
        for answered: PushRegistration.Status in [.denied, .authorized, .failed] {
            XCTAssertFalse(
                PushRegistration(status: answered).canRequestAuthorization,
                "\(answered) has already answered the system prompt, which never reappears")
        }
    }
}

/// What an install upgraded from a build with fewer fields reads back.
///
/// `UserDefaults` is the one place in this app where a value written by an older build is
/// guaranteed to turn up, and a decode that throws there is not a crash — it is a `nil` that reads
/// as a fresh install, so the app forgets a token the backend still holds and offers to enable
/// notifications that are already on.
final class PushRegistrationDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> PushRegistration {
        try JSONDecoder().decode(PushRegistration.self, from: Data(json.utf8))
    }

    func testAStoredRegistrationWithNoChannelFieldsStillLoads() throws {
        let state = try decode(
            #"{"status":"authorized","deviceToken":"abc","registeredToken":"abc"}"#)
        XCTAssertEqual(state.status, .authorized)
        XCTAssertEqual(state.registeredToken, "abc")
        XCTAssertEqual(state.mutedChannels, [])
        XCTAssertNil(state.registeredMutedChannels, "never told is not the same as told nothing is muted")
    }

    func testAnEmptyObjectLoadsAsAFreshInstall() throws {
        XCTAssertEqual(try decode("{}").status, .notRequested)
    }

    func testWhatIsWrittenIsWhatComesBack() throws {
        let written = PushRegistration(
            status: .authorized, deviceToken: "abc", registeredToken: "abc",
            mutedChannels: [.alerts], registeredMutedChannels: [.alerts], lastError: nil)
        let data = try JSONEncoder().encode(written)
        XCTAssertEqual(try JSONDecoder().decode(PushRegistration.self, from: data), written)
    }
}
