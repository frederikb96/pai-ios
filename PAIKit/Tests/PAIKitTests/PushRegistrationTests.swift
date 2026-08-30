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
            status: .authorized, deviceToken: "same", registeredToken: "same")
        XCTAssertFalse(state.needsBackendRegistration)
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
