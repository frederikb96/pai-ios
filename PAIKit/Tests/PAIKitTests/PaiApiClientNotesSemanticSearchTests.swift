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

    /// `/api/memory/search` is generic across memories, phase summaries and notes — forgetting
    /// the filter would silently widen every search to the whole corpus instead of throwing.
    func testSendsTheNoteTypeFilterAlongsideTheQueryAndLimit() async throws {
        stubJSON(#"{"count": 0, "results": []}"#)
        let client = try makeClient()
        _ = try await client.searchNotesSemantic(q: "kubernetes migration", limit: 42)

        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.url?.path, "/api/memory/search")
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.httpMethod, "POST")

        let body = String(data: PaiStubURLProtocol.capturedBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains(#""query":"kubernetes migration""#), body)
        XCTAssertTrue(body.contains(#""limit":42"#), body)
        XCTAssertTrue(body.contains(#""filter":{"type":"note"}"#), body)
    }

    func testDecodesTheNoteIdOutOfTheNestedMetadata() async throws {
        stubJSON(
            #"""
            {"count": 1, "results": [
                {"point_id": "p1", "type": "note", "text": "…", "score": 0.87,
                 "metadata": {"note_id": "n1"}, "created_at": "2026-01-01T00:00:00Z",
                 "updated_at": "2026-01-01T00:00:00Z"}
            ]}
            """#)
        let client = try makeClient()
        let hits = try await client.searchNotesSemantic(q: "x")

        XCTAssertEqual(hits, [NoteSemanticHit(noteId: "n1", score: 0.87)])
    }

    /// `type: "note"` metadata always carries `note_id` — `embed_note`'s job handler writes it as
    /// the row's whole metadata, backend-side. A hit missing it means the `type` filter itself
    /// stopped working, which should surface as a decode failure rather than a silently dropped
    /// row that reads as "no matches".
    func testAHitMissingNoteIdFailsTheDecodeRatherThanBeingSilentlyDropped() async throws {
        stubJSON(
            #"""
            {"count": 1, "results": [
                {"point_id": "p1", "type": "note", "text": "…", "score": 0.5,
                 "metadata": {}, "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z"}
            ]}
            """#)
        let client = try makeClient()
        do {
            _ = try await client.searchNotesSemantic(q: "x")
            XCTFail("expected a decode failure for a hit with no note_id")
        } catch {
            // Any thrown error is the point — the exact `PaiError` case is not what this asserts.
        }
    }
}
