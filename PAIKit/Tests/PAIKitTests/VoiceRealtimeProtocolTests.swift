import XCTest

@testable import PAIKit

final class VoiceRealtimeProtocolTests: XCTestCase {

    // MARK: URL construction

    func testConnectionURLOmitsLanguageCodeWhenAuto() throws {
        let url = try XCTUnwrap(
            VoiceRealtimeProtocol.connectionURL(token: "tok", sampleRate: 24000, language: .auto)
        )
        XCTAssertFalse(url.absoluteString.contains("language_code"))
    }

    func testConnectionURLIncludesLanguageCodeWhenSet() throws {
        let url = try XCTUnwrap(
            VoiceRealtimeProtocol.connectionURL(token: "tok", sampleRate: 24000, language: .de)
        )
        XCTAssertTrue(url.absoluteString.contains("language_code=de"), url.absoluteString)
    }

    func testConnectionURLCarriesTheNegotiatedSampleRateAndToken() throws {
        let url = try XCTUnwrap(
            VoiceRealtimeProtocol.connectionURL(token: "single-use-tok", sampleRate: 16000, language: .auto)
        )
        let query = url.query ?? ""
        XCTAssertTrue(query.contains("audio_format=pcm_16000"), query)
        XCTAssertTrue(query.contains("token=single-use-tok"), query)
    }

    // MARK: Uplink frame

    func testUplinkChunkEncodesTheDocumentedFieldNames() throws {
        let chunk = RealtimeUplinkChunk(audioBase64: "abc", commit: false, sampleRate: 24000)
        let json = try JSONSerialization.jsonObject(with: chunk.encoded()) as? [String: Any]
        XCTAssertEqual(json?["message_type"] as? String, "input_audio_chunk")
        XCTAssertEqual(json?["audio_base_64"] as? String, "abc")
        XCTAssertEqual(json?["commit"] as? Bool, false)
        XCTAssertEqual(json?["sample_rate"] as? Int, 24000)
    }

    /// The commit frame's payload must decode back to exactly
    /// `VoiceRealtimeProtocol.commitFrameSampleCount` samples of silence — sending anything else
    /// (an empty payload, non-zero bytes) is the kind of change a JSON-shape test alone would
    /// not catch.
    func testCommitFrameCarries240SamplesOfDigitalSilence() throws {
        let chunk = RealtimeUplinkChunk.commitFrame(sampleRate: 24000)
        XCTAssertTrue(chunk.commit)
        let bytes = try XCTUnwrap(Data(base64Encoded: chunk.audioBase64))
        XCTAssertEqual(bytes.count, VoiceRealtimeProtocol.commitFrameSampleCount * 2)
        XCTAssertTrue(bytes.allSatisfy { $0 == 0 })
    }

    /// Round-trips a small buffer through the little-endian packer to make sure byte order is
    /// actually little-endian rather than the platform's native order happening to agree with it
    /// on this machine.
    func testPCM16LEPackingIsLittleEndian() throws {
        let base64 = RealtimeUplinkChunk.audioBase64(fromPCM16LE: [0x0102, -1])
        let bytes = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertEqual(Array(bytes), [0x02, 0x01, 0xFF, 0xFF])
    }

    // MARK: Downlink decoding

    func testDecodesSessionStarted() {
        XCTAssertEqual(
            RealtimeDownlinkMessage.decode(#"{"message_type":"session_started"}"#), .sessionStarted
        )
    }

    func testDecodesPartialAndCommittedTranscripts() {
        XCTAssertEqual(
            RealtimeDownlinkMessage.decode(#"{"message_type":"partial_transcript","text":"hell"}"#),
            .partialTranscript(text: "hell")
        )
        XCTAssertEqual(
            RealtimeDownlinkMessage.decode(#"{"message_type":"committed_transcript","text":"hello"}"#),
            .committedTranscript(text: "hello")
        )
        XCTAssertEqual(
            RealtimeDownlinkMessage.decode(
                #"{"message_type":"committed_transcript_with_timestamps","text":"hello"}"#
            ),
            .committedTranscript(text: "hello")
        )
    }

    func testDecodesErrorMessage() {
        XCTAssertEqual(
            RealtimeDownlinkMessage.decode(#"{"message_type":"error","message":"bad token"}"#),
            .error(message: "bad token")
        )
    }

    /// A message type ElevenLabs adds later must decode to `.unrecognized` rather than `nil` or
    /// a crash — a live recording continuing to run through an unrecognised message is the whole
    /// point of this case existing.
    func testUnknownMessageTypeIsUnrecognizedNotNil() {
        XCTAssertEqual(
            RealtimeDownlinkMessage.decode(#"{"message_type":"future_thing"}"#),
            .unrecognized(messageType: "future_thing")
        )
    }

    func testMalformedJSONDecodesToNil() {
        XCTAssertNil(RealtimeDownlinkMessage.decode("not json at all"))
    }

    // MARK: Pre-connect buffer

    func testPreconnectBufferDrainsInEnqueueOrder() {
        var buffer = PreconnectAudioBuffer<Int>()
        buffer.enqueue(1)
        buffer.enqueue(2)
        buffer.enqueue(3)
        XCTAssertEqual(buffer.drain(), [1, 2, 3])
    }

    func testPreconnectBufferIsEmptyAfterDraining() {
        var buffer = PreconnectAudioBuffer<Int>()
        buffer.enqueue(1)
        _ = buffer.drain()
        XCTAssertEqual(buffer.drain(), [])
    }

    /// Drops the newest chunk once full, keeping the earliest audio — the start of the take is
    /// exactly what the buffer exists to protect, so overflow must never evict it.
    func testPreconnectBufferDropsOverflowRatherThanTheOldestChunk() {
        var buffer = PreconnectAudioBuffer<Int>()
        for value in 0..<(PreconnectAudioBuffer<Int>.capacity + 5) {
            buffer.enqueue(value)
        }
        let drained = buffer.drain()
        XCTAssertEqual(drained.count, PreconnectAudioBuffer<Int>.capacity)
        XCTAssertEqual(drained.first, 0)
        XCTAssertEqual(drained.last, PreconnectAudioBuffer<Int>.capacity - 1)
    }
}
