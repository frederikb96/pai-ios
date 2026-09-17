import XCTest

@testable import PAIKit

/// The manifest is a wire contract with an offline trainer outside this repo (`Tooling/wakeword`),
/// not merely an internal detail — so this pins the field names down explicitly rather than only
/// round-tripping through `WakeWordSample`'s own `Codable`, which would stay green even if every
/// key silently renamed itself in lockstep on both sides of an encode/decode pair.
final class WakeWordSampleManifestTests: XCTestCase {

    func testEncodeProducesAJSONArrayWithTheExpectedKeys() throws {
        let sample = WakeWordSample(
            id: "positive-loud-1-1000", kind: .positive, label: "loud", fileName: "positive-loud-1-1000.wav",
            recordedAtMs: 1000, durationMs: 850, sampleRate: 48000, microphoneRoute: "iPhone Microphone")

        let data = try WakeWordSampleManifest.encode([sample])
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(json.count, 1)
        let entry = json[0]

        XCTAssertEqual(entry["id"] as? String, "positive-loud-1-1000")
        XCTAssertEqual(entry["kind"] as? String, "positive")
        XCTAssertEqual(entry["label"] as? String, "loud")
        XCTAssertEqual(entry["fileName"] as? String, "positive-loud-1-1000.wav")
        XCTAssertEqual(entry["recordedAtMs"] as? Double, 1000)
        XCTAssertEqual(entry["durationMs"] as? Double, 850)
        XCTAssertEqual(entry["sampleRate"] as? Int, 48000)
        XCTAssertEqual(entry["microphoneRoute"] as? String, "iPhone Microphone")
    }

    func testEncodeRoundTripsThroughWakeWordSampleDecoding() throws {
        let samples = [
            WakeWordSample(
                id: "a", kind: .positive, label: "loud", fileName: "a.wav", recordedAtMs: 1, durationMs: 500,
                sampleRate: 16000, microphoneRoute: "AirPods"),
            WakeWordSample(
                id: "b", kind: .negative, label: "ambient", fileName: "b.wav", recordedAtMs: 2, durationMs: 1200,
                sampleRate: 48000, microphoneRoute: "iPhone Microphone"),
        ]
        let data = try WakeWordSampleManifest.encode(samples)
        let decoded = try JSONDecoder().decode([WakeWordSample].self, from: data)
        XCTAssertEqual(decoded, samples)
    }
}
