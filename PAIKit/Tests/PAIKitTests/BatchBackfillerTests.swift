import XCTest

@testable import PAIKit

/// Hands back the same fixed bytes for whatever range it is asked for — every test here drives
/// `BatchBackfiller.run` with exactly one request, so there is nothing to distinguish by range.
private struct FakeAudioReader: TakeAudioReader {
    var bytes: Data = Data()
    var error: Error?

    func readSamples(id: String, range: WavByteRange) async throws -> Data {
        if let error { throw error }
        return bytes
    }
}

final class BatchBackfillerTests: XCTestCase {

    private let sampleRate = 16000

    private func makeReader(pcm: [Int16]) -> FakeAudioReader {
        var bytes = Data()
        for sample in pcm {
            var little = sample.littleEndian
            withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
        }
        return FakeAudioReader(bytes: bytes)
    }

    func testSuccessfulBackfillProducesABatchSegmentWithTakeShiftedWordOffsets() async {
        // A gap at samples 32000..<48000, requested with a 1s (16000-sample) margin each side.
        let request = BackfillPlanner.Request(
            range: 32000..<48000, audioRange: 16000..<64000, gapRanges: [32000..<48000])
        let reader = makeReader(pcm: [Int16](repeating: 1, count: request.audioRange.count))

        let outcome = await BatchBackfiller.run(
            request, sampleRate: sampleRate, language: .auto, audioReader: reader, takeId: "take-1",
            transcribe: { _, _ in
                // Words at offset zero, relative to the request's own audio — as `batchTranscribe`
                // is contracted to return.
                (
                    text: "hello there",
                    words: [Word(range: 0..<8000, text: "hello"), Word(range: 8000..<16000, text: "there")]
                )
            }
        )

        guard case let .segment(segment) = outcome else { return XCTFail("expected a segment") }
        XCTAssertEqual(segment.source, .batch)
        XCTAssertEqual(segment.range, request.range, "the gap's own un-margined range, not the audio request's")
        XCTAssertEqual(segment.text, "hello there")
        // Shifted by the request's audio start (16000), not by the gap's own start (32000).
        XCTAssertEqual(segment.words?.map(\.range), [16000..<24000, 24000..<32000])
    }

    func testNoSpeechDetectedIsItsOwnOutcomeNotAFailure() async {
        let request = BackfillPlanner.Request(range: 0..<16000, audioRange: 0..<16000, gapRanges: [0..<16000])
        let reader = makeReader(pcm: [Int16](repeating: 0, count: 16000))

        let outcome = await BatchBackfiller.run(
            request, sampleRate: sampleRate, language: .auto, audioReader: reader, takeId: "take-1",
            transcribe: { _, _ in (text: "", words: []) }
        )
        XCTAssertEqual(outcome, .noSpeechDetected)
    }

    func testAReaderFailureIsReportedAsFailedRatherThanCrashing() async {
        let request = BackfillPlanner.Request(range: 0..<16000, audioRange: 0..<16000, gapRanges: [0..<16000])
        let reader = FakeAudioReader(error: VoiceSocketTransportError.notConnected)

        let outcome = await BatchBackfiller.run(
            request, sampleRate: sampleRate, language: .auto, audioReader: reader, takeId: "take-1",
            transcribe: { _, _ in (text: "unreachable", words: []) }
        )
        guard case .failed = outcome else { return XCTFail("expected .failed") }
    }

    func testATranscribeFailureIsReportedAsFailed() async {
        let request = BackfillPlanner.Request(range: 0..<16000, audioRange: 0..<16000, gapRanges: [0..<16000])
        let reader = makeReader(pcm: [Int16](repeating: 0, count: 16000))

        let outcome = await BatchBackfiller.run(
            request, sampleRate: sampleRate, language: .auto, audioReader: reader, takeId: "take-1",
            transcribe: { _, _ in throw VoiceSocketTransportError.notConnected }
        )
        guard case .failed = outcome else { return XCTFail("expected .failed") }
    }

    /// Empty audio (the range this backfill was asked for turned out to hold nothing, e.g. after
    /// a retention eviction raced it) must fail cleanly rather than post an empty file.
    func testEmptyAudioIsReportedAsFailedRatherThanPostingNothing() async {
        let request = BackfillPlanner.Request(range: 0..<16000, audioRange: 0..<16000, gapRanges: [0..<16000])
        let reader = FakeAudioReader(bytes: Data())

        let outcome = await BatchBackfiller.run(
            request, sampleRate: sampleRate, language: .auto, audioReader: reader, takeId: "take-1",
            transcribe: { _, _ in (text: "should not be called with this", words: []) }
        )
        guard case .failed = outcome else { return XCTFail("expected .failed") }
    }
}
