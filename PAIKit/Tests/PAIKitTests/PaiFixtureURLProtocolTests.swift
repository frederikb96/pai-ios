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

    /// `swift test`'s own process never carries `-PaiFixtureAuthState`, so this exercises the
    /// route's default branch — the one every screenshot that is not itself about the sign-in
    /// banner relies on staying the healthy body.
    func testClaudeAuthRouteDefaultsToTheHealthyBodyWithNoLaunchArgument() {
        let match = PaiFixtureURLProtocol.route(method: "GET", path: "/api/auth/claude")
        XCTAssertEqual(body(match), PaiFixtures.claudeAuthHealthy)
    }

    /// `/api/notes/config` is three path segments, same as `/api/notes/{id}` — table order is
    /// what keeps this the config fixture rather than a note whose id is "config".
    func testNotesConfigRouteIsNotReadAsANoteID() {
        let match = PaiFixtureURLProtocol.route(method: "GET", path: "/api/notes/config")
        XCTAssertEqual(match.status, 200)
        XCTAssertEqual(body(match), PaiFixtures.notesConfig)
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

    // MARK: - Query-driven paging (the .replaced landing path)

    private func decodeMessages(_ match: PaiFixtureURLProtocol.Match) -> [Message] {
        (try? JSONDecoder().decode([Message].self, from: match.body())) ?? []
    }

    func testMessagesRouteHonoursTailAndLimit() {
        let match = PaiFixtureURLProtocol.route(
            method: "GET", path: "/api/session/one/messages",
            query: [URLQueryItem(name: "tail", value: "true"), URLQueryItem(name: "limit", value: "5")])
        let messages = decodeMessages(match)
        XCTAssertEqual(messages.count, 5)
        XCTAssertEqual(messages.map(\.id).sorted(), messages.map(\.id), "a page must already be ascending")
    }

    /// The exact case this fixture corpus exists for: an `around_id` far from the tail must come
    /// back as a page that does not overlap the loaded tail window at all — the shape `locate`'s
    /// `mergeOrReplaceWindow` reads as "replace", never "merge" (search-virtualization design,
    /// "the around page, and merge-or-replace"). Proves the corpus is genuinely large enough,
    /// not just that paging code runs.
    func testAroundIdFarFromTheTailAnswersAPageThatDoesNotOverlapIt() {
        let tailMatch = PaiFixtureURLProtocol.route(
            method: "GET", path: "/api/session/one/messages", query: [URLQueryItem(name: "tail", value: "true")])
        let tailIds = decodeMessages(tailMatch).map(\.id)
        guard let oldestTailId = tailIds.min() else { return XCTFail("tail page returned nothing") }

        let aroundMatch = PaiFixtureURLProtocol.route(
            method: "GET", path: "/api/session/one/messages",
            query: [URLQueryItem(name: "around_id", value: "9029"), URLQueryItem(name: "limit", value: "150")])
        let aroundMessages = decodeMessages(aroundMatch)
        XCTAssertFalse(aroundMessages.isEmpty)
        XCTAssertTrue(aroundMessages.contains { $0.id == 9029 })
        XCTAssertLessThan(
            aroundMessages.map(\.id).max() ?? .max, oldestTailId,
            "the around page must not reach the tail window at all, or a merge would apply instead of a replace")
    }

    func testBeforeIdReturnsOlderRowsOnly() {
        let match = PaiFixtureURLProtocol.route(
            method: "GET", path: "/api/session/one/messages",
            query: [URLQueryItem(name: "before_id", value: "9010"), URLQueryItem(name: "limit", value: "3")])
        let ids = decodeMessages(match).map(\.id)
        XCTAssertEqual(ids, [9007, 9008, 9009])
    }

    func testAfterIdReturnsNewerRowsOnly() {
        let match = PaiFixtureURLProtocol.route(
            method: "GET", path: "/api/session/one/messages",
            query: [URLQueryItem(name: "after_id", value: "9050"), URLQueryItem(name: "limit", value: "3")])
        let ids = decodeMessages(match).map(\.id)
        XCTAssertEqual(ids, [9051, 9052, 9053])
    }

    func testNoRecognisedQueryStillAnswersTheWholeTranscript() {
        let match = PaiFixtureURLProtocol.route(method: "GET", path: "/api/session/one/messages", query: [])
        XCTAssertEqual(String(decoding: match.body(), as: UTF8.self), PaiFixtures.transcript)
    }

    // MARK: - /messages/find

    func testFindWithBoundaryKindReturnsSessionStartAndEveryCompactRow() {
        let match = PaiFixtureURLProtocol.route(
            method: "GET", path: "/api/session/one/messages/find",
            query: [URLQueryItem(name: "kind", value: "boundary")])
        let result = try? JSONDecoder().decode(MessageFindResult.self, from: match.body())
        XCTAssertEqual(result?.messageIds.first, 9001, "the session's own first row is always a boundary hit")
        XCTAssertTrue(result?.messageIds.contains(9042) ?? false, "message 9042 is the curated system/compact row")
        XCTAssertEqual(result?.total, result?.messageIds.count)
    }

    func testFindWithATextQueryMatchesContentCaseInsensitively() {
        let match = PaiFixtureURLProtocol.route(
            method: "GET", path: "/api/session/one/messages/find", query: [URLQueryItem(name: "q", value: "SONNET")])
        let result = try? JSONDecoder().decode(MessageFindResult.self, from: match.body())
        XCTAssertTrue(result?.messageIds.contains(9028) ?? false, "message 9028's content names Sonnet 5")
    }

    func testFindWithNoQueryOrKindReturnsNoHits() {
        let match = PaiFixtureURLProtocol.route(method: "GET", path: "/api/session/one/messages/find", query: [])
        let result = try? JSONDecoder().decode(MessageFindResult.self, from: match.body())
        XCTAssertEqual(result?.messageIds, [])
        XCTAssertEqual(result?.total, 0)
    }
}
