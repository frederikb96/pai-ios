import XCTest

@testable import PAIKit

final class VoiceTextAssemblyTests: XCTestCase {

    func testAssembledTextJoinsSegmentsInTakeOrder() {
        let ledger = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: "s", preText: "",
            segments: [
                Segment(range: 16000..<32000, text: "world", source: .live),
                Segment(range: 0..<16000, text: "hello", source: .live),
            ]
        )
        XCTAssertEqual(VoiceTextAssembly.assembledText(from: ledger), "hello world")
    }

    /// An inline marker at the spot a gap still occupies, in take order alongside real segments.
    func testAssembledTextInsertsAMarkerAtAnOpenGap() {
        let ledger = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: "s", preText: "",
            segments: [
                Segment(range: 0..<16000, text: "hello", source: .live),
                Segment(range: 48000..<64000, text: "world", source: .live),
            ],
            gaps: [Gap(range: 16000..<48000)]
        )
        XCTAssertEqual(VoiceTextAssembly.assembledText(from: ledger), "hello … world")
    }

    /// 🚨 Reads `ledger.gaps` directly — never re-derives. A batch backfill resolves a gap by
    /// removing it from `gaps` (`applyingBackfill`), not by extending `acknowledged`, so
    /// re-deriving here would resurrect a gap that has already been closed.
    func testAssembledTextShowsNoMarkerOnceAGapIsClosedInTheStoredList() {
        let ledger = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: "s", preText: "",
            segments: [
                Segment(range: 0..<16000, text: "hello", source: .live),
                Segment(range: 16000..<32000, text: "recovered", source: .batch),
                Segment(range: 32000..<48000, text: "world", source: .live),
            ],
            gaps: []  // already resolved by a prior applyingBackfill call
        )
        XCTAssertEqual(VoiceTextAssembly.assembledText(from: ledger), "hello recovered world")
    }

    func testAssembledPrefixedTextIsEmptyWhenThereIsNothingAtAll() {
        let ledger = TranscriptLedger(takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: "s", preText: "")
        XCTAssertEqual(VoiceTextAssembly.assembledPrefixedText(from: ledger), "")
    }

    func testAssembledPrefixedTextAddsThePrefixOnceWhenThereIsSomething() {
        let ledger = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: "s", preText: "",
            segments: [Segment(range: 0..<16000, text: "hello", source: .live)]
        )
        XCTAssertEqual(VoiceTextAssembly.assembledPrefixedText(from: ledger), "stt-rec: hello")
    }

    /// A gap-only ledger (nothing has committed yet) still gets a marker, never an empty string
    /// that would read as "nothing was said" when audio genuinely is missing.
    func testAssembledTextIsJustTheMarkerWhenNothingHasCommittedYet() {
        let ledger = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: "s", preText: "",
            gaps: [Gap(range: 0..<16000)]
        )
        XCTAssertEqual(VoiceTextAssembly.assembledText(from: ledger), "…")
    }

    /// The live path records audio delivery as one textless acknowledged range, so a take's words
    /// exist only as `liveText`. A take that later had a gap batch-filled must keep those words
    /// through both the fold and the backfill — the text a stored recording and a healed draft
    /// are built from.
    func testLiveWordsSurviveAFoldAndABackfillOfAnotherStretch() {
        let start = TranscriptLedger(takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: "s", preText: "")
        let folded = start.folding(
            liveSegments: [Segment(range: 0..<16000, text: "", source: .live)], capturedUpTo: 48000,
            newlyAcknowledged: [0..<16000, 32000..<48000],
            liveText: [
                LiveTextSegment(endSample: 15000, text: "hello"), LiveTextSegment(endSample: 47000, text: "world"),
            ]
        )
        XCTAssertEqual(VoiceTextAssembly.assembledText(from: folded), "hello … world")

        let healed = folded.applyingBackfill(
            newSegments: [Segment(range: 16000..<32000, text: "recovered", source: .batch)],
            resolved: [16000..<32000], failed: []
        )
        XCTAssertEqual(VoiceTextAssembly.assembledText(from: healed), "hello recovered world")
    }

    /// A later fold that names no live text keeps what the ledger already holds — the backfill
    /// loop and the final fold at stop must not erase the take's words between them.
    func testAFoldWithoutLiveTextKeepsTheStoredWords() {
        let ledger = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: "s", preText: "",
            liveText: [LiveTextSegment(endSample: 16000, text: "hello")]
        )
        let folded = ledger.folding(liveSegments: [], capturedUpTo: 16000, newlyAcknowledged: [0..<16000])
        XCTAssertEqual(VoiceTextAssembly.assembledText(from: folded), "hello")
    }
}
