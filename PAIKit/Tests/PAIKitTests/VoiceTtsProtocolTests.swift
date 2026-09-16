import XCTest

@testable import PAIKit

final class VoiceTtsProtocolTests: XCTestCase {

    // MARK: - Connection URL

    func testConnectionURLCarriesTheVoiceIdInThePathAndTheTokenAsSingleUseToken() throws {
        let url = try XCTUnwrap(VoiceTtsProtocol.connectionURL(voiceId: "abc123", token: "tok-xyz"))
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "api.elevenlabs.io")
        XCTAssertTrue(url.path.contains("/v1/text-to-speech/abc123/multi-stream-input"))
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(query.contains(URLQueryItem(name: "single_use_token", value: "tok-xyz")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "model_id", value: VoiceTtsProtocol.modelId)))
        XCTAssertTrue(query.contains(URLQueryItem(name: "output_format", value: "pcm_24000")))
    }

    // MARK: - Uplink frame shapes — only the fields ElevenLabs documents for each message type

    private func decodedFrame(_ message: TtsUplinkMessage) throws -> [String: Any] {
        let data = try message.encoded()
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    func testInitializeContextSendsASingleSpaceAndVoiceSettings() throws {
        let frame = try decodedFrame(.initializeContext(contextId: "ctx-1"))
        XCTAssertEqual(frame["text"] as? String, " ")
        XCTAssertEqual(frame["context_id"] as? String, "ctx-1")
        let voiceSettings = try XCTUnwrap(frame["voice_settings"] as? [String: Any])
        XCTAssertEqual(voiceSettings["speed"] as? Double, 1.0)
        XCTAssertNil(frame["close_context"])
        XCTAssertNil(frame["close_socket"])
    }

    func testSendTextOmitsFlushWhenFalseRatherThanSendingItAsFalse() throws {
        let frame = try decodedFrame(.sendText(contextId: "ctx-1", text: "hello ", flush: false))
        XCTAssertEqual(frame["text"] as? String, "hello ")
        XCTAssertNil(frame["flush"])
    }

    func testSendTextIncludesFlushTrueOnTheLastSentence() throws {
        let frame = try decodedFrame(.sendText(contextId: "ctx-1", text: "hello ", flush: true))
        XCTAssertEqual(frame["flush"] as? Bool, true)
    }

    func testCloseContextSendsTheContextIdAndCloseContextTrueOnly() throws {
        let frame = try decodedFrame(.closeContext(contextId: "ctx-1"))
        XCTAssertEqual(frame["context_id"] as? String, "ctx-1")
        XCTAssertEqual(frame["close_context"] as? Bool, true)
        XCTAssertNil(frame["text"])
    }

    func testCloseSocketSendsNothingButCloseSocketTrue() throws {
        let frame = try decodedFrame(.closeSocket)
        XCTAssertEqual(frame["close_socket"] as? Bool, true)
        XCTAssertNil(frame["context_id"])
        XCTAssertNil(frame["text"])
    }

    func testKeepContextAliveSendsAnEmptyStringNotNoTextAtAll() throws {
        let frame = try decodedFrame(.keepContextAlive(contextId: "ctx-1"))
        XCTAssertEqual(frame["text"] as? String, "")
        XCTAssertEqual(frame["context_id"] as? String, "ctx-1")
    }

    // MARK: - Downlink decoding

    func testAudioMessageDecodesWithItsContextIdAndBase64Payload() {
        let message = TtsDownlinkMessage.decode(#"{"audio":"YWJj","contextId":"ctx-1"}"#)
        XCTAssertEqual(message, .audio(contextId: "ctx-1", base64: "YWJj"))
    }

    func testFinalOutputDecodesAsContextFinished() {
        let message = TtsDownlinkMessage.decode(#"{"isFinal":true,"contextId":"ctx-1"}"#)
        XCTAssertEqual(message, .contextFinished(contextId: "ctx-1"))
    }

    func testAnUnrecognizedButWellFormedBodyIsDistinctFromADecodeFailure() {
        let message = TtsDownlinkMessage.decode(#"{"somethingElse":true}"#)
        XCTAssertEqual(message, .unrecognized(raw: #"{"somethingElse":true}"#))
    }

    func testGarbageThatIsNotEvenJsonDecodesToNilRatherThanUnrecognized() {
        XCTAssertNil(TtsDownlinkMessage.decode("not json at all"))
    }

    // MARK: - PCM decode round-trip

    func testPcm16SamplesRoundTripsWithRealtimeUplinkChunksOwnEncoder() {
        let original: [Int16] = [0, 1, -1, 32767, -32768, 1234, -1234]
        let base64 = RealtimeUplinkChunk.audioBase64(fromPCM16LE: original)
        XCTAssertEqual(VoiceTtsProtocol.pcm16Samples(fromBase64: base64), original)
    }

    func testFloatSamplesNormalisesFullScaleValuesToApproximatelyPlusOneAndMinusOne() throws {
        let base64 = RealtimeUplinkChunk.audioBase64(fromPCM16LE: [32767, -32768, 0])
        let floats = try XCTUnwrap(VoiceTtsProtocol.floatSamples(fromBase64: base64))
        XCTAssertEqual(floats.count, 3)
        XCTAssertEqual(floats[0], 1.0, accuracy: 0.001)
        XCTAssertEqual(floats[1], -1.0, accuracy: 0.001)
        XCTAssertEqual(floats[2], 0.0, accuracy: 0.001)
    }

    func testPcm16SamplesOfInvalidBase64IsNil() {
        XCTAssertNil(VoiceTtsProtocol.pcm16Samples(fromBase64: "not-valid-base64!!"))
    }
}
