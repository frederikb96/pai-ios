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

    // MARK: - coveredRanges / derivedGaps (microphone mode)

    func testCoveredRangesMergesAdjacentAndOverlappingSegments() {
        let ledger = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: nil, preText: "",
            segments: [
                Segment(range: 0..<1000, text: "a", source: .live),
                Segment(range: 1000..<2000, text: "b", source: .live),
                Segment(range: 1800..<2500, text: "c", source: .batch),
            ]
        )
        XCTAssertEqual(ledger.coveredRanges, [0..<2500])
    }

    /// The whole point of the ledger: audio captured with no committed segment over it is a gap,
    /// derived fresh from coverage rather than stored redundantly.
    func testDerivedGapsIsEverythingCapturedMinusEverythingCovered() {
        let ledger = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: nil, preText: "",
            segments: [Segment(range: 1000..<2000, text: "middle", source: .live)]
        )
        let gaps = ledger.derivedGaps(capturedUpTo: 5000)
        XCTAssertEqual(gaps.map(\.range), [0..<1000, 2000..<5000])
    }

    func testDerivedGapsIsEmptyWhenEverythingCapturedIsCovered() {
        let ledger = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: nil, preText: "",
            segments: [Segment(range: 0..<5000, text: "all", source: .live)]
        )
        XCTAssertTrue(ledger.derivedGaps(capturedUpTo: 5000).isEmpty)
    }

    /// A persisted gap's attempt count and demotion must survive being recomputed — the retry
    /// budget is a work item, not something a fresh derivation is allowed to reset.
    func testDerivedGapsCarriesForwardAttemptCountsFromAnOverlappingPersistedGap() {
        let ledger = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: nil, preText: "",
            gaps: [Gap(range: 1000..<2000, attempts: 3, lastError: "timeout", demoted: true)]
        )
        let gaps = ledger.derivedGaps(capturedUpTo: 2000)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.attempts, 3)
        XCTAssertEqual(gaps.first?.lastError, "timeout")
        XCTAssertEqual(gaps.first?.demoted, true)
    }

    // MARK: - collectingBounds (call mode)

    /// Call mode's gaps only ever come from the stretches between a start and a stop — audio
    /// captured while merely `listening` (no collecting range open) must never become a gap.
    func testCallModeOnlyCollectingRangesCanEverBecomeGaps() {
        let ledger = TranscriptLedger(
            takeId: "t", mode: .call, sampleRate: 16000, draftKey: "s", preText: "",
            collecting: [1000..<2000, 4000..<5000]
        )
        let gaps = ledger.derivedGaps(capturedUpTo: 6000)
        // Samples 0..<1000, 2000..<4000 and 5000..<6000 were captured (listening) but never
        // collecting, so they must not appear as gaps.
        XCTAssertEqual(gaps.map(\.range), [1000..<2000, 4000..<5000])
    }

    /// A `collecting` range still open (no stop yet) when the take ends must clamp to what has
    /// actually been captured rather than claiming samples that do not exist.
    func testCallModeCollectingRangeClampsToCapturedUpTo() {
        let ledger = TranscriptLedger(
            takeId: "t", mode: .call, sampleRate: 16000, draftKey: "s", preText: "", collecting: [1000..<1_000_000]
        )
        XCTAssertEqual(ledger.derivedGaps(capturedUpTo: 3000), [Gap(range: 1000..<3000)])
    }

    // MARK: - mayBeDeleted

    func testMayBeDeletedRequiresBothNoGapsAndDelivered() {
        let complete = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: nil, preText: "", delivered: true
        )
        XCTAssertTrue(complete.mayBeDeleted)

        let undelivered = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: nil, preText: "", delivered: false
        )
        XCTAssertFalse(undelivered.mayBeDeleted)

        let withOpenGap = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: nil, preText: "",
            gaps: [Gap(range: 0..<1000)], delivered: true
        )
        XCTAssertFalse(withOpenGap.mayBeDeleted)
    }
}
