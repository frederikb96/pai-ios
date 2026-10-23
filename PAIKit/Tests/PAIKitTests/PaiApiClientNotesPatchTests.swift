import Foundation
import XCTest

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import PAIKit

/// What `PATCH /api/notes/{id}` carries on the wire. An ordinary save has to stay the request it
/// always was; only an edit made offline names its side.
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

    func testAnOrdinarySaveSendsNoSource() async throws {
        _ = try await makeClient().patchNote(id: "n1", body: "text", frontmatter: "a: b", expectedHash: "h1")
        XCTAssertEqual(try sentKeys(), ["body", "frontmatter", "expected_hash"])
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
