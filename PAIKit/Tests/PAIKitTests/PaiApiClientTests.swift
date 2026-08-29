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

    // MARK: - Sessions

    /// The next page's cursor rides the `X-Next-Cursor` response HEADER, not the body — this is
    /// the one thing `getSessions` cannot get from `send()`'s ordinary JSON decode, and the
    /// reason it bypasses that path entirely.
    func testGetSessionsReadsNextCursorFromResponseHeaderNotBody() async throws {
        PaiStubURLProtocol.stub = .init(
            statusCode: 200,
            headers: ["Content-Type": "application/json", "X-Next-Cursor": "opaque-token"],
            body: Data("[]".utf8)
        )
        let client = try makeClient()
        let page = try await client.getSessions()

        XCTAssertEqual(page.nextCursor, "opaque-token")
        XCTAssertEqual(page.sessions.count, 0)
    }

    func testGetSessionsNextCursorIsNilWhenTheHeaderIsAbsent() async throws {
        stubJSON("[]")
        let client = try makeClient()
        let page = try await client.getSessions()
        XCTAssertNil(page.nextCursor)
    }

    /// `since` is the incremental-sync mode; `cursor`+filters is the browse mode — this only
    /// checks that every filter actually reaches the query string, since a dropped one would
    /// silently widen the result set rather than throwing.
    func testGetSessionsSendsEveryFilterOnTheQueryString() async throws {
        stubJSON("[]")
        let client = try makeClient()
        _ = try await client.getSessions(cursor: "c1", agent: "vm", kind: .subagent, parent: "p1", q: "hello")

        let query = PaiStubURLProtocol.capturedRequest?.url?.query ?? ""
        XCTAssertTrue(query.contains("cursor=c1"), query)
        XCTAssertTrue(query.contains("agent=vm"), query)
        XCTAssertTrue(query.contains("kind=subagent"), query)
        XCTAssertTrue(query.contains("parent=p1"), query)
        XCTAssertTrue(query.contains("q=hello"), query)
    }

    func testSearchSessionsSendsModeAndAgentWhenProvided() async throws {
        stubJSON("[]")
        let client = try makeClient()
        _ = try await client.searchSessions(q: "notes", mode: .semantic, agent: "vm", limit: 50)

        let query = PaiStubURLProtocol.capturedRequest?.url?.query ?? ""
        XCTAssertTrue(query.contains("q=notes"), query)
        XCTAssertTrue(query.contains("mode=semantic"), query)
        XCTAssertTrue(query.contains("agent=vm"), query)
        XCTAssertTrue(query.contains("limit=50"), query)
    }

    /// This app's reverse proxy serves the SPA's `index.html` for any unmatched web path, which
    /// answers 200 with an HTML-shaped-as-JSON body a naive decode could half-accept. Asserting
    /// on `status` here is what turns "route not yet deployed" into a thrown error instead of a
    /// resume the UI reports as having silently done nothing.
    func testResumeSessionThrowsOnAnUnrecognizedStatus() async throws {
        stubJSON(#"{"status":"unexpected_value"}"#)
        let client = try makeClient()
        do {
            _ = try await client.resumeSession(sessionId: "s1")
            XCTFail("Expected resumeSession to throw on an unrecognized status")
        } catch {
            // Any throw is correct here; the point is that it does not return silently.
        }
    }

    /// `nil` means "reset to the deployment default", which must reach the wire as an explicit
    /// `null` — Swift's synthesized `Encodable` would instead omit the key on `nil`, and this
    /// PATCH route treats an omitted key as "leave it alone", turning a reset into a no-op.
    func testSetIdleTimeoutSendsExplicitNullRatherThanOmittingTheKey() async throws {
        stubJSON(#"{"id":"s1","session_type":"claude","status":"active","session_tokens":0}"#)
        let client = try makeClient()
        _ = try await client.setIdleTimeout(sessionId: "s1", minutes: nil)

        let body = String(data: PaiStubURLProtocol.capturedBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains(#""idle_timeout_minutes":null"#), body)
    }

    func testResumeSessionAcceptsEveryRecognizedStatus() async throws {
        let client = try makeClient()
        for status in ["resumed", "already_running", "refused"] {
            stubJSON(#"{"status":"\#(status)"}"#)
            let result = try await client.resumeSession(sessionId: "s1")
            XCTAssertEqual(result.status.rawValue, status)
        }
    }

    // MARK: - App secrets & SMTP

    /// The secret's *name* becomes a path segment — a raw-value typo here (`smtpPassword`
    /// instead of `smtp_password`) would 404 against a real backend while compiling cleanly.
    func testSetSecretUsesTheBackendsSnakeCaseNameInThePath() async throws {
        stubJSON(#"{"set":true,"updated_at":null}"#)
        let client = try makeClient()
        _ = try await client.setSecret(name: .smtpPassword, value: "hunter2")

        let path = PaiStubURLProtocol.capturedRequest?.url?.path ?? ""
        XCTAssertTrue(path.hasSuffix("/api/settings/secrets/smtp_password"), path)
    }

    func testMintVoiceTokenEncodesPurposeAsSnakeCaseString() async throws {
        stubJSON(#"{"token":"t","expires_in":60}"#)
        let client = try makeClient()
        _ = try await client.mintVoiceToken(purpose: .batch)

        let body = String(data: PaiStubURLProtocol.capturedBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains(#""purpose":"batch""#), body)
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

    /// The regression this guards: `.urlPathAllowed` alone leaves `/` untouched (it is a legal
    /// *path* character), so a slash inside a draft key was previously carried straight through
    /// into a second path segment instead of staying part of the key.
    func testDeleteDraftPercentEncodesSlashInKeyExactlyOnce() async throws {
        stubJSON(#"{"key":"a/b","deleted":true}"#)
        let client = try makeClient()
        _ = try await client.deleteDraft(key: "a/b")

        guard let url = PaiStubURLProtocol.capturedRequest?.url else {
            return XCTFail("No request captured")
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertTrue((components?.percentEncodedPath ?? "").hasSuffix("/api/drafts/a%2Fb"))
    }

    /// A filename containing `"` must not be able to close the quoted `filename` parameter
    /// early — that would let the remainder of the name become unintended header parameters.
    func testPostMessageEscapesQuoteInFileFilename() async throws {
        stubJSON(#"{"session_id":"s1","message_id":9}"#)
        let client = try makeClient()
        let file = PaiFileUpload(
            filename: #"weird"name.txt"#, mimeType: "text/plain", data: Data("x".utf8)
        )
        _ = try await client.postMessage(message: "hello", files: [file])

        let body = String(data: PaiStubURLProtocol.capturedBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains(#"filename="weird\"name.txt""#), body)
        XCTAssertFalse(body.contains(#"filename="weird"name.txt""#), body)
    }

    func testPostMessageIncludesSessionIdWhenProvided() async throws {
        stubJSON(#"{"session_id":"s1","message_id":9}"#)
        let client = try makeClient()
        _ = try await client.postMessage(sessionId: "s1", message: "hello")

        let body = String(data: PaiStubURLProtocol.capturedBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("name=\"session_id\""), body)
        XCTAssertTrue(body.contains("s1"), body)
    }

    /// `agent` only matters on a create, and only when the caller actually named one — an
    /// unconditional emit would send an empty `agent` field on every existing-session send.
    func testPostMessageOmitsAgentFieldWhenNotProvided() async throws {
        stubJSON(#"{"session_id":"s1","message_id":9}"#)
        let client = try makeClient()
        _ = try await client.postMessage(sessionId: "s1", message: "hello")

        let body = String(data: PaiStubURLProtocol.capturedBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(body.contains("name=\"agent\""), body)
    }

    func testPostMessageIncludesAgentFieldWhenProvided() async throws {
        stubJSON(#"{"session_id":"s1","message_id":9}"#)
        let client = try makeClient()
        _ = try await client.postMessage(message: "hello", agent: "laptop")

        let body = String(data: PaiStubURLProtocol.capturedBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("name=\"agent\""), body)
        XCTAssertTrue(body.contains("laptop"), body)
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
        stubJSON(
            #"""
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
