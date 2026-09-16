import XCTest

@testable import PAIKit

final class VoiceCredentialRedactionTests: XCTestCase {
    func testRedactsATokenQueryParameterInAConnectionURL() {
        let url =
            "wss://api.elevenlabs.io/v1/speech-to-text/realtime?model_id=scribe_v2_realtime&token=abcDEF123456xyz"
        let redacted = VoiceCredentialRedaction.redact(url)
        XCTAssertFalse(redacted.contains("abcDEF123456xyz"))
        XCTAssertTrue(redacted.contains("token=<redacted>"))
        XCTAssertTrue(redacted.contains("model_id=scribe_v2_realtime"), "only the token, nothing else, is touched")
    }

    func testRedactsASingleUseTokenQueryParameterInATtsURL() {
        let url = "wss://api.elevenlabs.io/v1/text-to-speech/voice123/multi-stream-input?single_use_token=zyxTOKEN987"
        let redacted = VoiceCredentialRedaction.redact(url)
        XCTAssertFalse(redacted.contains("zyxTOKEN987"))
        XCTAssertTrue(redacted.contains("single_use_token=<redacted>"))
    }

    func testRedactsAnApiKeyHeaderValueHoweverItWasFormatted() {
        let dumped = "[\"xi-api-key\": \"sk_live_verySecretValue123\"]"
        let redacted = VoiceCredentialRedaction.redact(dumped)
        XCTAssertFalse(redacted.contains("sk_live_verySecretValue123"))
    }

    func testRedactsABearerAuthorizationHeaderValue() {
        let dumped = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.super.secret"
        let redacted = VoiceCredentialRedaction.redact(dumped)
        XCTAssertFalse(redacted.contains("eyJhbGciOiJIUzI1NiJ9.super.secret"))
        XCTAssertTrue(redacted.contains("Bearer <redacted>"))
    }

    func testLeavesTextWithNoCredentialShapeUntouched() {
        let text = "status 200, connected in 42ms, 3 words"
        XCTAssertEqual(VoiceCredentialRedaction.redact(text), text)
    }
}
