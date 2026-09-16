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
}
