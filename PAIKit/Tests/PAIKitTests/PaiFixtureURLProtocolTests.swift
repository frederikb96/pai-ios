import XCTest

@testable import PAIKit

/// Exercises `PaiFixtureURLProtocol.route(method:path:)` directly rather than through a live
/// `URLRequest` and `URLSession` round trip — the routing decision is a pure function of method
/// and path, and testing it that way needs no simulator and no registered protocol class.
final class PaiFixtureURLProtocolTests: XCTestCase {

    private func body(_ match: PaiFixtureURLProtocol.Match) -> String {
        String(decoding: match.body(), as: UTF8.self)
    }

    func testKnownGetRouteAnswers200WithTheMatchingFixture() {
        let match = PaiFixtureURLProtocol.route(method: "GET", path: "/api/agents")
        XCTAssertEqual(match.status, 200)
        XCTAssertEqual(body(match), PaiFixtures.agents)
    }

    /// The query string is not part of `.path`, so a request carrying one — every real call to
    /// `/api/sessions` does — must still hit the exact-match route rather than falling through
    /// to the 404 default.
    func testQueryStringDoesNotPreventAnExactMatch() {
        let match = PaiFixtureURLProtocol.route(method: "GET", path: "/api/sessions")
        XCTAssertEqual(match.status, 200)
        XCTAssertEqual(body(match), PaiFixtures.sessions)
    }

    func testSessionScopedRouteMatchesAnyID() {
        let first = PaiFixtureURLProtocol.route(method: "GET", path: "/api/session/one/messages")
        let second = PaiFixtureURLProtocol.route(method: "GET", path: "/api/session/305df4d3/messages")
        XCTAssertEqual(body(first), PaiFixtures.transcript)
        XCTAssertEqual(body(second), PaiFixtures.transcript)
    }

    /// The method matters as much as the path: a `POST` to a `GET`-only route is a different
    /// request the table has no entry for, not a fuzzy match on the path alone.
    func testMethodMismatchFallsThroughToTheDefault() {
        let match = PaiFixtureURLProtocol.route(method: "POST", path: "/api/agents")
        XCTAssertEqual(match.status, 404)
    }

    func testUnknownPathAnswersWithAWellFormedErrorDetailBody() {
        let match = PaiFixtureURLProtocol.route(method: "GET", path: "/api/does-not-exist")
        XCTAssertEqual(match.status, 404)

        struct ErrorBody: Decodable { let detail: String }
        let decoded = try? JSONDecoder().decode(ErrorBody.self, from: match.body())
        XCTAssertEqual(decoded?.detail, "no fixture route for GET /api/does-not-exist")
    }
}
