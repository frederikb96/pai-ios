import XCTest

@testable import PAIKit

final class CallCycleAddressingTests: XCTestCase {

    // MARK: - Plain shifting

    func testShiftingARangeAddsTheBaseToBothBounds() {
        XCTAssertEqual(CallCycleAddressing.shift(100..<200, by: 1000), 1100..<1200)
    }

    func testShiftingAWordMovesItsRangeAndKeepsItsTextAndLogprob() {
        let word = Word(range: 50..<100, text: "hello", logprob: -0.2)
        let shifted = CallCycleAddressing.shift(word, by: 1000)
        XCTAssertEqual(shifted.range, 1050..<1100)
        XCTAssertEqual(shifted.text, "hello")
        XCTAssertEqual(shifted.logprob, -0.2)
    }

    func testShiftingASegmentMovesItsRangeAndEveryWordsRangeButNotItsText() {
        let segment = Segment(
            range: 0..<500, text: "hello world",
            words: [Word(range: 0..<200, text: "hello"), Word(range: 250..<500, text: "world")], source: .live)
        let shifted = CallCycleAddressing.shift(segment, by: 2000)
        XCTAssertEqual(shifted.range, 2000..<2500)
        XCTAssertEqual(shifted.text, "hello world")
        XCTAssertEqual(shifted.source, .live)
        XCTAssertEqual(shifted.words?.map(\.range), [2000..<2200, 2250..<2500])
    }

    func testASegmentWithNoWordsShiftsWithoutCrashing() {
        let segment = Segment(range: 0..<500, text: "hello", source: .batch)
        XCTAssertNil(CallCycleAddressing.shift(segment, by: 100).words)
    }

    func testShiftingAnArrayShiftsEveryElementByTheSameBase() {
        let segments = [
            Segment(range: 0..<100, text: "a", source: .live),
            Segment(range: 100..<200, text: "b", source: .live),
        ]
        let shifted = CallCycleAddressing.shift(segments, by: 500)
        XCTAssertEqual(shifted.map(\.range), [500..<600, 600..<700])
    }

    // MARK: - A scripted connection drop inside one cycle, stitched with a second cycle

    /// The scenario the healing feature exists for, built entirely from values — no live socket,
    /// no `VoiceRecordingSession` — since everything call mode's own drop-recovery needs beyond
    /// what a microphone-mode take already proves is this shift arithmetic feeding the *same*
    /// `TranscriptLedger`/`SeamMerge` machinery. Cycle 1: audio committed, then a drop (nothing
    /// committed for a stretch, captured audio still advances), then a batch backfill recovers the
    /// dropped stretch before "stop". Cycle 2 (after a wake-mode gap the call ledger's own
    /// addressing never represents at all): a second, ordinary cycle. The merged, call-wide result
    /// must carry every word exactly once, in order, across both cycles, with no gap remaining.
    func testAConnectionDropWithinOneCycleHealsToEveryWordExactlyOnceOnceBackfilled() {
        // Cycle 1, addressed from zero exactly as a microphone-mode take is: "one two" committed
        // live, then the socket drops for 1000 samples (audio still captured, nothing committed),
        // then "three four" backfills the drop.
        let cycle1Live = [Segment(range: 0..<500, text: "one two", source: .live)]
        let cycle1CapturedUpTo = 1500

        let cycle1Base = 0
        var callSegments = CallCycleAddressing.shift(cycle1Live, by: cycle1Base)
        var callCapturedUpTo = cycle1Base + cycle1CapturedUpTo
        var callCollecting: [SampleRange] = [CallCycleAddressing.shift(0..<cycle1CapturedUpTo, by: cycle1Base)]

        var ledger = TranscriptLedger(
            takeId: "call-1", mode: .call, sampleRate: 16000, draftKey: "session-1", preText: "",
            segments: callSegments, capturedUpTo: callCapturedUpTo, collecting: callCollecting)
        XCTAssertEqual(
            ledger.derivedGaps(capturedUpTo: callCapturedUpTo).map(\.range), [500..<1500],
            "the drop must derive as exactly one gap, bounded to the collecting range")

        // The batch backfill recovers the dropped stretch — shifted the same way a live segment
        // would be, since the shift function does not care about `Segment.Source`.
        let recovered = CallCycleAddressing.shift(
            Segment(range: 500..<1500, text: "three four", source: .batch), by: cycle1Base)
        callSegments = SeamMerge.merge(callSegments + [recovered])
        ledger = TranscriptLedger(
            takeId: ledger.takeId, mode: .call, sampleRate: 16000, draftKey: "session-1", preText: "",
            segments: callSegments, capturedUpTo: callCapturedUpTo, collecting: callCollecting)
        XCTAssertTrue(
            ledger.derivedGaps(capturedUpTo: callCapturedUpTo).isEmpty, "healed — nothing left uncovered")

        // Cycle 1 ends ("stop"/"send"): the call's own running position advances by exactly what
        // cycle 1 captured. A wake-mode stretch follows — never written to disk, never part of
        // this addressing at all, which is what keeps the two cycles contiguous here even though
        // real time passed between them.
        let callTakeCollectedSamplesAfterCycle1 = cycle1Base + cycle1CapturedUpTo

        // Cycle 2, addressed from zero again (a fresh `VoiceRecordingSession`), shifted by the
        // call's new running position.
        let cycle2Live = [Segment(range: 0..<800, text: "five six seven", source: .live)]
        let cycle2Base = callTakeCollectedSamplesAfterCycle1
        callSegments = SeamMerge.merge(callSegments + CallCycleAddressing.shift(cycle2Live, by: cycle2Base))
        callCapturedUpTo = cycle2Base + 800
        callCollecting.append(CallCycleAddressing.shift(0..<800, by: cycle2Base))

        ledger = TranscriptLedger(
            takeId: ledger.takeId, mode: .call, sampleRate: 16000, draftKey: "session-1", preText: "",
            segments: callSegments, capturedUpTo: callCapturedUpTo, collecting: callCollecting)

        XCTAssertTrue(ledger.derivedGaps(capturedUpTo: callCapturedUpTo).isEmpty)
        let fullText = callSegments.sorted { $0.range.lowerBound < $1.range.lowerBound }.map(\.text).joined(
            separator: " ")
        XCTAssertEqual(fullText, "one two three four five six seven", "every word exactly once, in order")
    }

    /// The bound `derivedGaps` uses for `.call` mode is `collecting`, never `0..<capturedUpTo` the
    /// way `.microphone` mode's is — without a `collecting` entry for the open cycle, a drop would
    /// never derive as a gap at all, silently losing the words rather than healing them.
    func testWithNoCollectingRangeACallLedgerNeverDerivesAGapEvenWithAnObviousHole() {
        let ledger = TranscriptLedger(
            takeId: "call-1", mode: .call, sampleRate: 16000, draftKey: "session-1", preText: "",
            segments: [Segment(range: 0..<500, text: "one two", source: .live)], capturedUpTo: 1500)
        XCTAssertTrue(
            ledger.derivedGaps(capturedUpTo: 1500).isEmpty,
            "documents the trap this feature exists to avoid — collecting must be kept current")
    }
}
