import XCTest
@testable import PAIKit

/// `getMessages`'s three navigation modes are the sharpest silent-breakage risk in this file —
/// swapping `before_id`/`after_id`, or leaking `tail=true` alongside an id, pages the transcript
/// from the wrong end without ever throwing. Everything else here targets a similarly silent
/// failure: a body sent where none is expected, a query param dropped, an error body ignored.
final class PaiApiClientTests: XCTestCase {

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
            statusCode: statusCode,
            headers: ["Content-Type": "application/json"],
            body: Data(json.utf8)
        )
    }

    func testGetMessagesBeforeModeSendsBeforeIdNotAfterId() async throws {
        stubJSON("[]")
        let client = try makeClient()
        _ = try await client.getMessages(sessionId: "s1", page: .before(id: 42, limit: 10))

        let query = PaiStubURLProtocol.capturedRequest?.url?.query ?? ""
        XCTAssertTrue(query.contains("before_id=42"), query)
        XCTAssertTrue(query.contains("limit=10"), query)
        XCTAssertFalse(query.contains("after_id"), query)
        XCTAssertFalse(query.contains("tail"), query)
    }

    func testGetMessagesTailModeSendsTailTrue() async throws {
        stubJSON("[]")
        let client = try makeClient()
        _ = try await client.getMessages(sessionId: "s1", page: .tail(limit: 20))

        let query = PaiStubURLProtocol.capturedRequest?.url?.query ?? ""
        XCTAssertTrue(query.contains("tail=true"), query)
        XCTAssertFalse(query.contains("before_id"), query)
        XCTAssertFalse(query.contains("after_id"), query)
    }

    func testGetMessagesAfterModeSendsAfterIdNotBeforeId() async throws {
        stubJSON("[]")
        let client = try makeClient()
        _ = try await client.getMessages(sessionId: "s1", page: .after(id: 7, limit: nil))

        let query = PaiStubURLProtocol.capturedRequest?.url?.query ?? ""
        XCTAssertTrue(query.contains("after_id=7"), query)
        XCTAssertFalse(query.contains("before_id"), query)
        XCTAssertFalse(query.contains("limit"), query)
    }

    func testBodylessPostSendsNoContentTypeAndNoBody() async throws {
        stubJSON(#"{"status":"cancelled"}"#)
        let client = try makeClient()
        _ = try await client.cancelSession(sessionId: "s1")

        XCTAssertNil(PaiStubURLProtocol.capturedRequest?.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(PaiStubURLProtocol.capturedBody?.isEmpty ?? true)
    }

    func testPostMessageSendsMultipartWithBoundaryAndOmitsAbsentFields() async throws {
        stubJSON(#"{"session_id":"s1","message_id":9}"#)
        let client = try makeClient()
        _ = try await client.postMessage(message: "hello")

        let contentType = PaiStubURLProtocol.capturedRequest?.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="), contentType)

        let body = String(data: PaiStubURLProtocol.capturedBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("name=\"message\""), body)
        XCTAssertTrue(body.contains("hello"), body)
        // No sessionId/sessionType/workingDir were passed, so none of their field names appear —
        // an unconditional emit here would send an empty session_id and route the send down the
        // "existing session" branch server-side instead of creating one.
        XCTAssertFalse(body.contains("name=\"session_id\""), body)
        XCTAssertFalse(body.contains("name=\"session_type\""), body)
        XCTAssertFalse(body.contains("name=\"working_dir\""), body)
    }

    func testPostMessageIncludesSessionIdWhenProvided() async throws {
        stubJSON(#"{"session_id":"s1","message_id":9}"#)
        let client = try makeClient()
        _ = try await client.postMessage(sessionId: "s1", message: "hello")

        let body = String(data: PaiStubURLProtocol.capturedBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("name=\"session_id\""), body)
        XCTAssertTrue(body.contains("s1"), body)
    }

    func testErrorResponseSurfacesServerDetailThroughTheRealDecodePath() async throws {
        stubJSON(#"{"detail":"session not found"}"#, statusCode: 404)
        let client = try makeClient()

        do {
            _ = try await client.getSessions()
            XCTFail("Expected getSessions to throw")
        } catch let error as PaiError {
            XCTAssertEqual(error.userMessage, "session not found")
        }
    }

    func testGetHealthDecodesTheBackendsActualShapeNotTypesTs() async throws {
        // `types.ts` declares `status: 'ok' | 'degraded'` with no `credential` field; the real
        // backend (`api.py`) sends `'ok' | 'unavailable'` plus `credential`. This proves the
        // deliberately loose `HealthResponse` (plain `String`s) survives that mismatch rather
        // than throwing a decode error on a live, healthy pod.
        stubJSON(#"""
        {"status":"unavailable","database":"unavailable","agent":"disconnected",
         "credential":"unknown","timestamp":"2026-08-24T00:00:00Z"}
        """#)
        let client = try makeClient()
        let health = try await client.getHealth()

        XCTAssertEqual(health.status, "unavailable")
        XCTAssertEqual(health.credential, "unknown")
    }

    func testExportSessionUsesServerFilenameFromContentDisposition() async throws {
        PaiStubURLProtocol.stub = .init(
            statusCode: 200,
            headers: ["Content-Disposition": #"attachment; filename="pai-export-2026.json""#],
            body: Data("{}".utf8)
        )
        let client = try makeClient()
        let result = try await client.exportSession(sessionId: "s1")

        XCTAssertEqual(result.filename, "pai-export-2026.json")
    }

    func testExportSessionFallsBackToDefaultFilenameWithoutContentDisposition() async throws {
        PaiStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data("{}".utf8))
        let client = try makeClient()
        let result = try await client.exportSession(sessionId: "s1")

        XCTAssertEqual(result.filename, "pai-session-s1-export.json")
    }

    func testParseContentDispositionFilenameHandlesQuotedAndUnquotedForms() {
        XCTAssertEqual(
            PaiApiClient.parseContentDispositionFilename(#"attachment; filename="a b.json""#),
            "a b.json"
        )
        XCTAssertEqual(
            PaiApiClient.parseContentDispositionFilename("attachment; filename=plain.json"),
            "plain.json"
        )
        XCTAssertNil(PaiApiClient.parseContentDispositionFilename("attachment"))
    }

    func testGetAttachmentDistinguishesNotFoundFromError() async throws {
        let client = try makeClient()

        PaiStubURLProtocol.stub = .init(statusCode: 404, headers: [:], body: Data())
        guard case .notFound = try await client.getAttachment(sessionId: "s1", path: "p") else {
            return XCTFail("Expected .notFound")
        }

        PaiStubURLProtocol.stub = .init(
            statusCode: 500, headers: [:], body: Data(#"{"detail":"boom"}"#.utf8)
        )
        guard case let .error(error) = try await client.getAttachment(sessionId: "s1", path: "p") else {
            return XCTFail("Expected .error")
        }
        XCTAssertEqual(error.userMessage, "boom")
    }
}
