import Foundation
import XCTest

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import PAIKit

/// What `PATCH /api/notes/{id}` carries on the wire. The client sends `source` only when asked;
/// the store asks on every content save, naming the phone, so its writes never fold into the
/// web's version history.
final class PaiApiClientNotesPatchTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PaiStubURLProtocol.reset()
        PaiStubURLProtocol.stub = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(PaiFixtures.noteDetail.utf8))
    }

    private func makeClient() throws -> PaiApiClient {
        let factory = try PaiRequestFactory(baseURL: "https://pai.example.com", tokenProvider: { "jwt" })
        return PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
    }

    private func sentKeys() throws -> Set<String> {
        let body = try XCTUnwrap(PaiStubURLProtocol.capturedBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return Set(object.keys)
    }

    func testTheClientSendsNoSourceUnlessAsked() async throws {
        _ = try await makeClient().patchNote(id: "n1", body: "text", frontmatter: "a: b", expectedHash: "h1")
        XCTAssertEqual(try sentKeys(), ["body", "frontmatter", "expected_hash"])
    }

    /// The store's online save over the real client: the request carries the body, the
    /// frontmatter it was read with, the hash it is conditional on, and the phone as its side —
    /// nothing else.
    @MainActor
    func testAnOnlineSaveFromTheStoreNamesThePhone() async throws {
        let detail = try JSONDecoder().decode(NoteDetail.self, from: Data(PaiFixtures.noteDetail.utf8))
        let store = NotesStore(api: try makeClient())
        await store.loadNote(id: detail.id)
        XCTAssertEqual(store.detail(for: detail.id)?.contentHash, detail.contentHash)

        store.edit(id: detail.id, body: detail.body + " and one more line")
        await store.flush(id: detail.id)

        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.httpMethod, "PATCH")
        let body = try XCTUnwrap(PaiStubURLProtocol.capturedBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["body", "frontmatter", "expected_hash", "source"])
        XCTAssertEqual(object["source"] as? String, "phone")
        XCTAssertEqual(object["expected_hash"] as? String, detail.contentHash)
    }

    func testAnOfflineSaveNamesItsSource() async throws {
        _ = try await makeClient().patchNote(
            id: "n1", body: "text", frontmatter: nil, expectedHash: "h1", source: NoteWriteSource.offline)
        let body = try XCTUnwrap(PaiStubURLProtocol.capturedBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["source"] as? String, "offline")
        XCTAssertEqual(object["expected_hash"] as? String, "h1")
    }
}
