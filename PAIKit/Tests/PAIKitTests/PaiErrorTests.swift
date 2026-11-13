import XCTest

@testable import PAIKit

/// Which refusals mean "the credential is bad" (sign out) and which mean "not allowed" (stay).
final class PaiErrorTests: XCTestCase {

    func testA401IsARejectedCredential() {
        XCTAssertTrue(PaiError.from(statusCode: 401, body: Data(#"{"detail":"expired"}"#.utf8)).isAuthenticationFailure)
        XCTAssertTrue(PaiError.from(statusCode: 401, body: Data()).isAuthenticationFailure)
    }

    /// The ingress proxy answers an invalid bearer with a plain-text 403.
    func testAPlainTextProxy403IsARejectedCredential() {
        let error = PaiError.from(statusCode: 403, body: Data("Forbidden".utf8))
        XCTAssertTrue(error.isAuthenticationFailure)
        XCTAssertFalse(error.isRefusal)
    }

    /// pai-cloud's own 403 carries a JSON `detail`: the credential is fine, this person may not.
    func testAJson403IsARefusalAndKeepsTheSignIn() {
        let error = PaiError.from(statusCode: 403, body: Data(#"{"detail":"owner only"}"#.utf8))
        XCTAssertFalse(error.isAuthenticationFailure)
        XCTAssertTrue(error.isRefusal)
        XCTAssertEqual(error.userMessage, "owner only")
    }

    func testOtherFailuresAreNeither() {
        for error in [
            PaiError.from(statusCode: 500, body: Data(#"{"detail":"boom"}"#.utf8)),
            PaiError.from(statusCode: 404, body: Data()),
            PaiError.transport("offline"),
            PaiError.decoding("bad"),
        ] {
            XCTAssertFalse(error.isAuthenticationFailure)
            XCTAssertFalse(error.isRefusal)
        }
    }
}
