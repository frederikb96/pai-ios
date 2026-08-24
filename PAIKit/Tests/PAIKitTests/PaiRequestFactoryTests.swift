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

    /// `URLComponents` leaves a literal `+` in a query value alone — it is a legal query
    /// character per RFC 3986 — but the backend decodes the query as
    /// `application/x-www-form-urlencoded`, where `+` means space. A VM path or attachment
    /// filename containing `+` must round-trip as itself, not as a space.
    func testQueryValueEscapesLiteralPlusRatherThanLeavingItAsASpace() throws {
        let factory = try PaiRequestFactory(
            baseURL: "https://pai.example.com", tokenProvider: { nil }
        )
        let request = try factory.makeRequest(
            path: "/api/browse",
            query: [URLQueryItem(name: "path", value: "a+b")]
        )
        let raw = request.url?.absoluteString ?? ""
        XCTAssertTrue(raw.contains("path=a%2Bb"), raw)
        XCTAssertFalse(raw.contains("path=a+b"), raw)
    }

    /// `PaiRequestFactory` joins `baseURL.path` and `path` via `percentEncodedPath`, which passes
    /// an already-encoded path through untouched — the regression this guards is a return to
    /// `appendingPathComponent`, which would re-encode a pre-encoded segment (`%2F` becoming
    /// `%252F`, see `PaiApiClient`'s draft key encoding).
    func testPreEncodedPathSegmentSurvivesWithoutBeingReEncoded() throws {
        let factory = try PaiRequestFactory(
            baseURL: "https://pai.example.com", tokenProvider: { nil }
        )
        let request = try factory.makeRequest(path: "/api/drafts/a%2Fb")
        let raw = request.url?.absoluteString ?? ""
        XCTAssertTrue(raw.hasSuffix("/api/drafts/a%2Fb"), raw)
        XCTAssertFalse(raw.contains("%25"), raw)
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
