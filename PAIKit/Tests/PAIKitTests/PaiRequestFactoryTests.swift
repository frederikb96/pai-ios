import XCTest
@testable import PAIKit

/// These cover the rules that are easy to break and silent when broken — the scheme guard, the
/// trailing-slash join, and reading the token at send time rather than at construction. Straight
/// URL concatenation is not tested; it would pass without proving anything.
final class PaiRequestFactoryTests: XCTestCase {

    func testRejectsNonHttpScheme() {
        XCTAssertThrowsError(
            try PaiRequestFactory(baseURL: "ftp://example.com", tokenProvider: { nil })
        ) { error in
            XCTAssertEqual(
                error as? PaiRequestFactory.ConfigurationError,
                .unsupportedScheme("ftp")
            )
        }
    }

    func testRejectsEmptyBaseURL() {
        XCTAssertThrowsError(
            try PaiRequestFactory(baseURL: "   ", tokenProvider: { nil })
        ) { error in
            XCTAssertEqual(error as? PaiRequestFactory.ConfigurationError, .emptyBaseURL)
        }
    }

    func testTrailingSlashDoesNotDoubleUp() throws {
        let factory = try PaiRequestFactory(
            baseURL: "https://pai.example.com/",
            tokenProvider: { nil }
        )
        let request = try factory.makeRequest(path: "/api/health")
        XCTAssertEqual(request.url?.absoluteString, "https://pai.example.com/api/health")
    }

    /// The token is read per request, so entering one in settings takes effect immediately
    /// rather than on the next launch.
    func testTokenIsReadAtSendTimeNotConstructionTime() throws {
        nonisolated(unsafe) var token: String? = nil
        let factory = try PaiRequestFactory(
            baseURL: "https://pai.example.com",
            tokenProvider: { token }
        )

        let before = try factory.makeRequest(path: "/api/health")
        XCTAssertNil(before.value(forHTTPHeaderField: "Authorization"))

        token = "jwt-value"
        let after = try factory.makeRequest(path: "/api/health")
        XCTAssertEqual(after.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-value")
    }

    func testEmptyTokenSendsNoAuthorizationHeader() throws {
        let factory = try PaiRequestFactory(
            baseURL: "https://pai.example.com",
            tokenProvider: { "" }
        )
        let request = try factory.makeRequest(path: "/api/health")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testErrorPrefersServerDetailOverStatusLine() {
        let body = Data(#"{"detail":"session not found"}"#.utf8)
        XCTAssertEqual(PaiError.from(statusCode: 404, body: body).userMessage, "session not found")
    }

    func testErrorFallsBackToStatusLineOnNonJsonBody() {
        let error = PaiError.from(statusCode: 502, body: Data("<html>".utf8))
        XCTAssertTrue(error.userMessage.hasPrefix("HTTP 502:"))
    }
}
