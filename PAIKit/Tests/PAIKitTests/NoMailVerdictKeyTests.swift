import XCTest

@testable import PAIKit

/// A message to an assistant session carries the caller's own bearer and device name like every
/// other request, and no MailVerdict key header: the backend forwards the bearer.
final class NoMailVerdictKeyTests: XCTestCase {
    func testAMessageToAnAssistantSessionCarriesNoKeyHeader() async throws {
        let factory = try PaiRequestFactory(
            baseURL: "https://pai.example.com", deviceName: "Test iPhone", tokenProvider: { "jwt" })
        let client = PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
        PaiStubURLProtocol.stub = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"],
            body: Data(#"{"session_id":"s1","message_id":1,"duplicate":false,"draft_version":1}"#.utf8))

        _ = try await client.postMessage(message: "hi", sessionType: "mailverdict")

        let request = try XCTUnwrap(PaiStubURLProtocol.capturedRequest)
        XCTAssertNil(request.value(forHTTPHeaderField: "X-MailVerdict-Key"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer jwt")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Name"), "Test iPhone")
    }
}
