import XCTest

@testable import PAIKit

/// Reuses `PaiStubURLProtocol` (`PaiApiClientTests`' fixture) rather than a second copy — it is
/// a plain `URLProtocol` stub with no PAI-backend assumptions baked in, and this is exactly the
/// kind of request/response round trip it exists to intercept.
final class VoiceBatchTranscriberTests: XCTestCase {

    override func tearDown() {
        PaiStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeTranscriber() -> VoiceBatchTranscriber {
        VoiceBatchTranscriber(urlSession: PaiStubURLProtocol.makeSession())
    }

    private func stubJSON(_ json: String, statusCode: Int = 200) {
        PaiStubURLProtocol.stub = .init(
            statusCode: statusCode, headers: ["Content-Type": "application/json"], body: Data(json.utf8)
        )
    }

    func testSuccessfulResponseReturnsTheTranscribedText() async throws {
        stubJSON(#"{"text":"hello there"}"#)
        let result = try await makeTranscriber().transcribe(
            wav: Data([1, 2, 3]), token: "tok", language: .auto
        )
        XCTAssertEqual(result, .text("hello there"))
    }

    /// An empty `text` in an otherwise-2xx response is a distinct outcome from a transport
    /// failure — the caller should not retry a silent recording the way it would retry a
    /// dropped connection.
    func testEmptyTextIsNoSpeechDetectedNotAFailure() async throws {
        stubJSON(#"{"text":""}"#)
        let result = try await makeTranscriber().transcribe(
            wav: Data([1, 2, 3]), token: "tok", language: .auto
        )
        XCTAssertEqual(result, .noSpeechDetected)
    }

    func testNon2xxStatusMapsToFailedWithTheStatusCode() async throws {
        stubJSON(#"{"detail":"invalid token"}"#, statusCode: 401)
        let result = try await makeTranscriber().transcribe(
            wav: Data([1, 2, 3]), token: "tok", language: .auto
        )
        guard case let .failed(error) = result else {
            return XCTFail("expected .failed for a 401 response")
        }
        XCTAssertEqual(error, .detail("invalid token", statusCode: 401))
    }

    func testTokenIsSentAsAQueryParameterNotAHeader() async throws {
        stubJSON(#"{"text":"x"}"#)
        _ = try await makeTranscriber().transcribe(wav: Data(), token: "single-use-tok", language: .auto)
        let request = try XCTUnwrap(PaiStubURLProtocol.capturedRequest)
        XCTAssertTrue(request.url?.query?.contains("token=single-use-tok") ?? false)
        XCTAssertNil(request.value(forHTTPHeaderField: "xi-api-key"))
    }

    // MARK: Multipart body — pure, no network

    func testMultipartBodyOmitsLanguageCodeFieldWhenAuto() {
        let body = VoiceBatchTranscriber.multipartBody(wav: Data([1]), language: .auto, boundary: "B")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(text.contains("language_code"))
        XCTAssertTrue(text.contains("model_id"))
        XCTAssertTrue(text.contains(VoiceBatchTranscriber.modelId))
    }

    func testMultipartBodyIncludesLanguageCodeFieldWhenSet() {
        let body = VoiceBatchTranscriber.multipartBody(wav: Data([1]), language: .de, boundary: "B")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"language_code\""))
        XCTAssertTrue(text.contains("\r\nde\r\n"))
    }

    func testMultipartBodyCarriesTheWavBytesUnderTheFileField() {
        let wav = Data([0xFF, 0x00, 0x11])
        let body = VoiceBatchTranscriber.multipartBody(wav: wav, language: .auto, boundary: "B")
        XCTAssertTrue(body.contains(wav.first!))  // sanity: bytes really are appended
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("filename=\"recording.wav\""))
        XCTAssertTrue(text.contains("Content-Type: audio/wav"))
    }
}
