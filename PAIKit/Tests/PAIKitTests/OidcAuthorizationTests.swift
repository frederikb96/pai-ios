import Foundation
import XCTest

@testable import PAIKit

/// The half of signing in that happens before any network call: the PKCE challenge the provider
/// checks the verifier against, and deciding whether a redirect answers this attempt.
final class OidcAuthorizationTests: XCTestCase {

    private let configuration = OidcConfiguration(
        issuer: URL(string: "https://login.example.invalid")!,
        clientId: "client-1",
        redirectURI: URL(string: "pai://oauth/callback")!,
        scopes: ["openid", "offline_access"]
    )

    /// RFC 7636, appendix B. A wrong challenge is refused by the provider at the token exchange,
    /// after the person has already typed their password.
    func testTheChallengeIsTheRfcS256OfTheVerifier() {
        let request = OidcAuthorizationRequest(
            configuration: configuration, codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "s")
        XCTAssertEqual(request.codeChallenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    /// FIPS 180-4 vectors whose padding spills into a second block, and a message of several
    /// blocks: the cases a one-block verifier never reaches.
    func testTheDigestHoldsAcrossBlockBoundaries() {
        func hex(_ text: String) -> String {
            Sha256.digest(Array(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(
            hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(
            hex(String(repeating: "a", count: 1000)),
            "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
        XCTAssertEqual(hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testTheAuthorizationUrlCarriesTheChallengeAndState() throws {
        let request = OidcAuthorizationRequest(configuration: configuration)
        let items = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        XCTAssertEqual(value("code_challenge"), request.codeChallenge)
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("state"), request.state)
        XCTAssertEqual(value("redirect_uri"), "pai://oauth/callback")
        XCTAssertEqual(value("response_type"), "code")
    }

    /// Fresh per attempt, URL-safe, and long enough for RFC 7636 (43 to 128 characters).
    func testEveryAttemptGetsItsOwnVerifierAndState() {
        let first = OidcAuthorizationRequest(configuration: configuration)
        let second = OidcAuthorizationRequest(configuration: configuration)
        XCTAssertNotEqual(first.codeVerifier, second.codeVerifier)
        XCTAssertNotEqual(first.state, second.state)
        XCTAssertEqual(first.codeVerifier.count, 43)
        XCTAssertNil(first.codeVerifier.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    func testTheCodeIsReadFromThisAttemptsCallback() throws {
        let request = OidcAuthorizationRequest(configuration: configuration, state: "abc")
        XCTAssertEqual(
            try request.authorizationCode(from: URL(string: "pai://oauth/callback?code=xyz&state=abc")!), "xyz")
    }

    /// A callback for another attempt (a stale tab, a forged link) must not be exchanged.
    func testACallbackWithAnotherStateIsRefused() {
        let request = OidcAuthorizationRequest(configuration: configuration, state: "abc")
        XCTAssertThrowsError(
            try request.authorizationCode(from: URL(string: "pai://oauth/callback?code=xyz&state=other")!)
        ) { XCTAssertEqual($0 as? OidcError, .stateMismatch) }
        XCTAssertThrowsError(try request.authorizationCode(from: URL(string: "pai://oauth/callback?code=xyz")!)) {
            XCTAssertEqual($0 as? OidcError, .stateMismatch)
        }
    }

    /// The app's own deep links share the `pai` scheme; one of them is not a sign-in answer.
    func testADeepLinkOnTheSameSchemeIsNotACallback() {
        let request = OidcAuthorizationRequest(configuration: configuration, state: "abc")
        XCTAssertThrowsError(try request.authorizationCode(from: URL(string: "pai://session/x?code=xyz&state=abc")!)) {
            XCTAssertEqual($0 as? OidcError, .unexpectedCallback)
        }
    }

    func testTheProvidersRefusalIsShownWithItsReason() {
        let request = OidcAuthorizationRequest(configuration: configuration, state: "abc")
        let callback = URL(
            string: "pai://oauth/callback?error=access_denied&error_description=No%20grant&state=abc")!
        XCTAssertThrowsError(try request.authorizationCode(from: callback)) {
            XCTAssertEqual($0 as? OidcError, .denied("No grant"))
        }
    }
}
