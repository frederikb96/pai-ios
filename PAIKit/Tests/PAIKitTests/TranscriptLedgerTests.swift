import XCTest

@testable import PAIKit

final class TranscriptLedgerTests: XCTestCase {

    /// Every array populated, every optional set — the shape most likely to expose a field a
    /// hand-written `CodingKeys` (there is none here, but a future one might) forgot to carry.
    func testTranscriptLedgerRoundTripsWithEverythingPopulated() throws {
        let ledger = TranscriptLedger(
            takeId: "1700000000000",
            mode: .call,
            sampleRate: 24000,
            draftKey: "session-1",
            preText: "already typed ",
            segments: [
                Segment(
                    range: 0..<48000, text: "hello there",
                    words: [Word(range: 0..<24000, text: "hello", logprob: -0.1)], source: .live
                )
            ],
            capturedUpTo: 96000,
            gaps: [Gap(range: 48000..<96000, attempts: 2, lastError: "timeout", demoted: true)],
            boundaries: [MessageBoundary(atOffset: 48000, kind: .stop, sentMessageId: "msg-1")],
            collecting: [0..<96000],
            events: [
                PipelineEvent(atOffset: 24000, wallClock: Date(timeIntervalSince1970: 1_700_000_000), kind: .drop)
            ],
            delivered: true
        )
        let data = try JSONEncoder().encode(ledger)
        let decoded = try JSONDecoder().decode(TranscriptLedger.self, from: data)
        XCTAssertEqual(decoded, ledger)
    }

    /// A recovered take with no known draft and nothing transcribed yet — the emptiest real
    /// ledger the recovery pass (§3) constructs.
    func testTranscriptLedgerRoundTripsWithNoDraftKeyAndEmptyCollections() throws {
        let ledger = TranscriptLedger(
            takeId: "1700000000001", mode: .microphone, sampleRate: 16000, draftKey: nil, preText: ""
        )
        let data = try JSONEncoder().encode(ledger)
        let decoded = try JSONDecoder().decode(TranscriptLedger.self, from: data)
        XCTAssertEqual(decoded, ledger)
        XCTAssertTrue(decoded.segments.isEmpty)
        XCTAssertFalse(decoded.delivered)
    }

    func testSegmentRoundTripsWithNoWords() throws {
        let segment = Segment(range: 10..<20, text: "hi", source: .recovery)
        let data = try JSONEncoder().encode(segment)
        let decoded = try JSONDecoder().decode(Segment.self, from: data)
        XCTAssertEqual(decoded, segment)
        XCTAssertNil(decoded.words)
    }

    func testTranscriptionMetaRoundTrips() throws {
        let meta = TranscriptionMeta(coveredMs: 4200, gapMs: 800, gapCount: 1, state: .pending, delivered: false)
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(TranscriptionMeta.self, from: data)
        XCTAssertEqual(decoded, meta)
    }

    /// `RecordingMeta` predates this field — every field past `durationMs` must stay optional so
    /// a recording saved before this design shipped still decodes.
    func testRecordingMetaRoundTripsWithoutTranscription() throws {
        let meta = RecordingMeta(timestampMs: 1_700_000_000_000, durationMs: 5000)
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(RecordingMeta.self, from: data)
        XCTAssertNil(decoded.transcription)
    }

    func testRecordingMetaRoundTripsWithTranscription() throws {
        let transcription = TranscriptionMeta(
            coveredMs: 5000, gapMs: 0, gapCount: 0, state: .complete, delivered: true
        )
        let meta = RecordingMeta(timestampMs: 1_700_000_000_000, durationMs: 5000, transcription: transcription)
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(RecordingMeta.self, from: data)
        XCTAssertEqual(decoded.transcription, transcription)
    }
}
