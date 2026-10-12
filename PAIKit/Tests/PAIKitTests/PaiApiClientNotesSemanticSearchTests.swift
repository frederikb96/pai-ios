import XCTest

@testable import PAIKit

final class PaiApiClientNotesSemanticSearchTests: XCTestCase {

    override func tearDown() {
        PaiStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() throws -> PaiApiClient {
        let factory = try PaiRequestFactory(baseURL: "https://pai.example.com", tokenProvider: { "jwt" })
        return PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
    }

    private func stubJSON(_ json: String, statusCode: Int = 200) {
        PaiStubURLProtocol.stub = .init(
            statusCode: statusCode, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
    }

    func testSendsTheQueryAndWindowToTheNotesRoute() async throws {
        stubJSON(#"{"results": []}"#)
        let client = try makeClient()
        let bounds = TimeBounds(
            since: Date(timeIntervalSince1970: 1_800_000_000), until: Date(timeIntervalSince1970: 1_800_086_400))
        _ = try await client.searchNotesSemantic(q: "kubernetes migration", window: bounds)

        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.url?.path, "/api/notes/semantic")
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.httpMethod, "GET")
        let query = PaiStubURLProtocol.capturedRequest?.url?.query ?? ""
        XCTAssertTrue(query.contains("q=kubernetes%20migration") || query.contains("q=kubernetes+migration"), query)
        XCTAssertTrue(query.contains("since=2027-01-15T08:00:00.000%2B00:00"), query)
        XCTAssertTrue(query.contains("until=2027-01-16T08:00:00.000%2B00:00"), query)
    }

    func testSendsNoWindowParametersWithoutAWindow() async throws {
        stubJSON(#"{"results": []}"#)
        let client = try makeClient()
        _ = try await client.searchNotesSemantic(q: "x")

        let query = PaiStubURLProtocol.capturedRequest?.url?.query ?? ""
        XCTAssertFalse(query.contains("since") || query.contains("until"), query)
    }

    func testDecodesTheHitsInTheOrderTheBackendSentThem() async throws {
        stubJSON(#"{"results": [{"note_id": "n2", "tier": 1}, {"note_id": "n1", "tier": 2}]}"#)
        let client = try makeClient()
        let hits = try await client.searchNotesSemantic(q: "x")

        XCTAssertEqual(hits, [NoteSemanticHit(noteId: "n2", tier: 1), NoteSemanticHit(noteId: "n1", tier: 2)])
    }

    /// A hit without a tier would be drawn in the wrong bucket; the decode must refuse it rather
    /// than guess.
    func testAHitMissingItsTierFailsTheDecode() async throws {
        stubJSON(#"{"results": [{"note_id": "n1"}]}"#)
        let client = try makeClient()
        do {
            _ = try await client.searchNotesSemantic(q: "x")
            XCTFail("expected a decode failure for a hit with no tier")
        } catch {
            // Any thrown error is the point — the exact `PaiError` case is not what this asserts.
        }
    }
}
