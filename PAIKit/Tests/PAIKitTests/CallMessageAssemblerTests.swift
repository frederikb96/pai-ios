import XCTest

@testable import PAIKit

final class CallMessageAssemblerTests: XCTestCase {

    private func ledger(segments: [Segment] = [], gaps: [Gap] = []) -> TranscriptLedger {
        TranscriptLedger(
            takeId: "take-1", mode: .call, sampleRate: 16000, draftKey: "session-1", preText: "",
            segments: segments, gaps: gaps
        )
    }

    // MARK: - Coverage

    func testARangeWithNoOverlappingGapIsCovered() {
        let ledger = ledger(gaps: [Gap(range: 500..<600)])
        XCTAssertTrue(CallMessageAssembler.isCovered([0..<100], in: ledger))
    }

    func testARangeOverlappingAGapIsNotCovered() {
        let ledger = ledger(gaps: [Gap(range: 50..<150)])
        XCTAssertFalse(CallMessageAssembler.isCovered([0..<100], in: ledger))
    }

    func testAGapExactlyAdjacentToTheRangeDoesNotCountAsOverlapping() {
        // `Range` overlap is exclusive of the upper bound — a gap starting exactly where the
        // range ends has genuinely not touched it.
        let ledger = ledger(gaps: [Gap(range: 100..<200)])
        XCTAssertTrue(CallMessageAssembler.isCovered([0..<100], in: ledger))
    }

    func testAnEmptyGapListMeansEverythingIsCovered() {
        let ledger = ledger(gaps: [])
        XCTAssertTrue(CallMessageAssembler.isCovered([0..<1_000_000], in: ledger))
    }

    // MARK: - Coverage across several ranges (a turn spanning more than one start/stop cycle)

    func testEveryRangeMustBeCoveredNotJustOne() {
        let ledger = ledger(gaps: [Gap(range: 850..<900)])
        XCTAssertFalse(
            CallMessageAssembler.isCovered([0..<100, 800..<1000], in: ledger),
            "a gap in the second range must still block the whole turn")
    }

    func testAllRangesCoveredWithAGapOutsideEveryOneOfThemIsStillCovered() {
        let ledger = ledger(gaps: [Gap(range: 300..<400)])
        XCTAssertTrue(
            CallMessageAssembler.isCovered([0..<100, 800..<1000], in: ledger),
            "the gap sits in the wake-mode stretch between the two ranges, not inside either")
    }

    // MARK: - Assembly

    func testSegmentsAreJoinedInOffsetOrderRegardlessOfLedgerStorageOrder() {
        let ledger = ledger(segments: [
            Segment(range: 200..<300, text: "world", source: .live),
            Segment(range: 0..<100, text: "hello", source: .live),
        ])
        XCTAssertEqual(CallMessageAssembler.assembledText(for: [0..<300], in: ledger), "hello world")
    }

    func testASegmentOutsideTheRequestedRangeIsExcludedEvenIfItOverlaps() {
        let ledger = ledger(segments: [
            Segment(range: 0..<100, text: "before", source: .live),
            Segment(range: 100..<200, text: "inside", source: .live),
        ])
        XCTAssertEqual(CallMessageAssembler.assembledText(for: [100..<200], in: ledger), "inside")
    }

    func testAssembledTextForARangeWithNoSegmentsAtAllIsEmpty() {
        let ledger = ledger(segments: [])
        XCTAssertEqual(CallMessageAssembler.assembledText(for: [0..<100], in: ledger), "")
    }

    func testAPartiallyOverlappingSegmentIsStillIncludedWhole() {
        // The planner's own margin means a segment's range can extend slightly past a boundary —
        // `overlaps`, not "fully contained", is the right test, and the whole segment's text
        // (not a trimmed slice of it) is what gets joined.
        let ledger = ledger(segments: [
            Segment(range: 90..<150, text: "spanning", source: .live)
        ])
        XCTAssertEqual(CallMessageAssembler.assembledText(for: [0..<100], in: ledger), "spanning")
    }

    func testSegmentsFromSeveralRangesAreJoinedInOffsetOrderAndTheGapBetweenThemContributesNothing() {
        let ledger = ledger(segments: [
            Segment(range: 800..<1000, text: "second half", source: .live),
            Segment(range: 0..<100, text: "first half", source: .live),
            Segment(range: 300..<400, text: "said in wake mode, not part of this turn", source: .live),
        ])
        XCTAssertEqual(
            CallMessageAssembler.assembledText(for: [0..<100, 800..<1000], in: ledger), "first half second half")
    }
}
