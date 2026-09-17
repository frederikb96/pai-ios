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

    func testShiftingAnArrayOfRangesShiftsEveryElementByTheSameBase() {
        let ranges: [SampleRange] = [0..<100, 200..<300]
        XCTAssertEqual(CallCycleAddressing.shift(ranges, by: 1000), [1000..<1100, 1200..<1300])
    }

    func testShiftingAnEmptyArrayOfRangesStaysEmpty() {
        XCTAssertEqual(CallCycleAddressing.shift([SampleRange](), by: 1000), [])
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
        // live — and so acknowledged — over the first 500 samples, then the socket drops for
        // 1000 samples (audio still captured to disk, nothing sent or acknowledged), then a batch
        // backfill recovers the dropped stretch before "stop".
        let cycle1Live = [Segment(range: 0..<500, text: "one two", source: .live)]
        let cycle1Acknowledged: [SampleRange] = [0..<500]
        let cycle1CapturedUpTo = 1500

        let cycle1Base = 0
        let callCapturedUpTo1 = cycle1Base + cycle1CapturedUpTo
        var callCollecting: [SampleRange] = [CallCycleAddressing.shift(0..<cycle1CapturedUpTo, by: cycle1Base)]
        // The call's own cumulative live picture across every cycle so far — exactly
        // `CallModeController.persistCallLedger()`'s own `completedCycleSegments`, which
        // `folding`'s own `liveSegments:` argument must be handed in full each time (it only ever
        // re-includes `.batch`/`.recovery` segments already in the ledger, never `.live` ones
        // from an earlier fold).
        var callLiveSegments = CallCycleAddressing.shift(cycle1Live, by: cycle1Base)

        // `folding` is the exact function a periodic ledger write already goes through — this is
        // what `CallModeController.persistCallLedger()` calls indirectly via
        // `persistExternalLedger`, never a hand-rolled equivalent.
        var ledger = TranscriptLedger(
            takeId: "call-1", mode: .call, sampleRate: 16000, draftKey: "session-1", preText: ""
        )
        .folding(
            liveSegments: callLiveSegments, capturedUpTo: callCapturedUpTo1,
            newlyAcknowledged: CallCycleAddressing.shift(cycle1Acknowledged, by: cycle1Base),
            collecting: callCollecting)
        XCTAssertEqual(
            ledger.gaps.map(\.range), [500..<1500],
            "the drop must derive as exactly one gap, bounded to the collecting range")

        // The batch backfill recovers the dropped stretch — shifted the same way a live segment
        // would be, since the shift function does not care about `Segment.Source`. Backfilled
        // audio heals the gap directly (`applyingBackfill`'s own contract, matching what the real
        // backfill loop does to the ledger); it is never folded into `acknowledged`, which tracks
        // only what the live connection itself confirmed.
        let recovered = CallCycleAddressing.shift(
            Segment(range: 500..<1500, text: "three four", source: .batch), by: cycle1Base)
        ledger = ledger.applyingBackfill(newSegments: [recovered], resolved: [500..<1500], failed: [])
        XCTAssertTrue(ledger.gaps.isEmpty, "healed — nothing left uncovered")

        // Cycle 1 ends ("stop"/"send"): the call's own running position advances by exactly what
        // cycle 1 captured. A wake-mode stretch follows — never written to disk, never part of
        // this addressing at all, which is what keeps the two cycles contiguous here even though
        // real time passed between them.
        let callTakeCollectedSamplesAfterCycle1 = cycle1Base + cycle1CapturedUpTo

        // Cycle 2, addressed from zero again (a fresh `VoiceRecordingSession`), shifted by the
        // call's new running position — fully committed live, so fully acknowledged too.
        // `folding`'s own contract re-includes cycle 1's batch-recovered "three four" from the
        // ledger's current state on its own; cycle 1's own live "one two" only survives because
        // `callLiveSegments` still carries it forward, exactly as `CallModeController`'s own
        // `completedCycleSegments` does.
        let cycle2Live = [Segment(range: 0..<800, text: "five six seven", source: .live)]
        let cycle2Acknowledged: [SampleRange] = [0..<800]
        let cycle2Base = callTakeCollectedSamplesAfterCycle1
        let callCapturedUpTo2 = cycle2Base + 800
        callCollecting.append(CallCycleAddressing.shift(0..<800, by: cycle2Base))
        callLiveSegments += CallCycleAddressing.shift(cycle2Live, by: cycle2Base)

        ledger = ledger.folding(
            liveSegments: callLiveSegments, capturedUpTo: callCapturedUpTo2,
            newlyAcknowledged: CallCycleAddressing.shift(cycle2Acknowledged, by: cycle2Base),
            collecting: callCollecting)

        XCTAssertTrue(ledger.gaps.isEmpty)
        let fullText = ledger.segments.sorted { $0.range.lowerBound < $1.range.lowerBound }.map(\.text).joined(
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

    // MARK: - Translating the offline engine's own offset into the call ledger's addressing

    /// A manual Send tapped during the first cycle closed the turn at offset 0 — an empty range —
    /// and three minutes of dictation were reported as nothing transcribed.
    func testAManualStopOrSendClosesAtTheEndOfWhatWasCollected() {
        XCTAssertEqual(
            CallCycleAddressing.closingStamp(spokenAtOffset: nil, collectedAfterCycleEnd: 2_880_000), 2_880_000)
        XCTAssertEqual(
            CallCycleAddressing.closingStamp(spokenAtOffset: 160_800, collectedAfterCycleEnd: 2_880_000), 160_800)
    }

    func testTranslateWakeWordOffsetIsHowFarIntoTheCycleThePlusHowFarTheCallHadAlreadyGone() {
        let translated = CallCycleAddressing.translateWakeWordOffset(
            50_000, wakeOffsetAtCycleStart: 20_000, callTakeCollectedSamples: 100_000)
        // 30,000 samples into the cycle, landing at 130,000 in the call's own addressing.
        XCTAssertEqual(translated, 130_000)
    }

    func testTranslateWakeWordOffsetAtTheVeryStartOfACycleIsJustCallTakeCollectedSamples() {
        let translated = CallCycleAddressing.translateWakeWordOffset(
            20_000, wakeOffsetAtCycleStart: 20_000, callTakeCollectedSamples: 100_000)
        XCTAssertEqual(translated, 100_000)
    }

    /// The actual bug on a device: `dispatch(.send)` used to stamp the command with the cycle's
    /// end — after `endCollectingCycle()` has folded in the offline detector's own latency and
    /// the wait for the final commit — which put the stamp seconds past where the words were
    /// spoken, well outside `CommandWindowStripper`'s fallback window. Translating from the
    /// engine's own offset instead lands within reach of it.
    func testTheCycleEndStampMissesComputerSendButTheTranslatedOfflineOffsetReachesIt() {
        let rate = 16_000.0
        let spoken: [Word] = [
            Word(range: 128_000..<134_400, text: "going"),  // 8.0s-8.4s
            Word(range: 134_400..<137_600, text: "to"),  // 8.4s-8.6s
            Word(range: 137_600..<144_000, text: "say"),  // 8.6s-9.0s
            Word(range: 160_000..<164_800, text: "computer"),  // 10.0s-10.3s
            Word(range: 166_400..<172_800, text: "send"),  // 10.4s-10.8s
        ]
        let ledger = TranscriptLedger(
            takeId: "call", mode: .call, sampleRate: Int(rate), draftKey: "s", preText: "",
            segments: [
                Segment(
                    range: spoken.first!.range.lowerBound..<spoken.last!.range.upperBound,
                    text: spoken.map(\.text).joined(separator: " "), words: spoken, source: .live)
            ], capturedUpTo: 212_800, collecting: [0..<212_800], acknowledged: [0..<212_800])

        // The cycle-end stamp: ~1.0s offline-detection latency + ~1.5s final-commit wait after
        // "send" ended at 10.8s — this is what `callTakeCollectedSamples` read after
        // `endCollectingCycle()` before the fix.
        let cycleEndStamp = CommandEvent(kind: .send, atOffset: 212_800, confidence: 1)
        let cycleEndText = CallMessageAssembler.assembledText(
            for: [0..<212_800], in: ledger, strippingCommands: [cycleEndStamp])
        XCTAssertEqual(
            cycleEndText, "going to say computer send", "documents the bug: the stamp never reaches the words")

        // The offline engine's own offset, translated: the detector fired at wake-word-listener
        // offset 260,800 (wherever call entry put it), the cycle itself started at 100,000 in
        // that same addressing, and the call's own ledger position when the cycle opened was 0.
        let translated = CallCycleAddressing.translateWakeWordOffset(
            260_800, wakeOffsetAtCycleStart: 100_000, callTakeCollectedSamples: 0)
        XCTAssertEqual(translated, 160_800, "just past 'computer' starting at 10.0s — the engine's own detection lag")
        let translatedStamp = CommandEvent(kind: .send, atOffset: translated, confidence: 1)
        let translatedText = CallMessageAssembler.assembledText(
            for: [0..<212_800], in: ledger, strippingCommands: [translatedStamp])
        XCTAssertEqual(translatedText, "going to say", "the translated offset is inside the stripper's window")
    }
}
