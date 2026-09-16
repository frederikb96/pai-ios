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

    /// The whole point of the ledger: audio captured on a connection that never went on to
    /// acknowledge it is a gap, derived fresh from `acknowledged` rather than stored redundantly.
    /// Deliberately *not* built from word coverage — see the sharp case below.
    func testDerivedGapsIsEverythingCapturedMinusEverythingAcknowledged() {
        let ledger = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: nil, preText: "",
            acknowledged: [1000..<2000]
        )
        let gaps = ledger.derivedGaps(capturedUpTo: 5000)
        XCTAssertEqual(gaps.map(\.range), [0..<1000, 2000..<5000])
    }

    func testDerivedGapsIsEmptyWhenEverythingCapturedIsAcknowledged() {
        let ledger = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: nil, preText: "",
            acknowledged: [0..<5000]
        )
        XCTAssertTrue(ledger.derivedGaps(capturedUpTo: 5000).isEmpty)
    }

    /// The sharp case: an ordinary pause between two committed words must never read as a gap.
    /// Word extents cover only `[0..<1000)` and `[3000..<4000)`, but the whole
    /// stretch was acknowledged (sent on a connection that went on to commit), so there is
    /// silence in the middle and zero gaps — the opposite of what deriving from `coveredRanges`
    /// used to produce.
    func testAnOrdinaryPauseBetweenAcknowledgedWordsIsNeverAGap() {
        let ledger = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: nil, preText: "",
            segments: [
                Segment(range: 0..<1000, text: "hello", source: .live),
                Segment(range: 3000..<4000, text: "world", source: .live),
            ],
            acknowledged: [0..<4000]
        )
        XCTAssertTrue(ledger.derivedGaps(capturedUpTo: 4000).isEmpty)
    }

    /// A persisted gap's attempt count and demotion must survive being recomputed — the retry
    /// budget is a work item, not something a fresh derivation is allowed to reset.
    func testDerivedGapsCarriesForwardAttemptCountsFromAnOverlappingPersistedGap() {
        let ledger = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: nil, preText: "",
            gaps: [Gap(range: 1000..<2000, attempts: 3, lastError: "timeout", demoted: true)],
            acknowledged: [0..<1000]
        )
        let gaps = ledger.derivedGaps(capturedUpTo: 2000)
        XCTAssertEqual(gaps.map(\.range), [1000..<2000])
        XCTAssertEqual(gaps.first?.attempts, 3)
        XCTAssertEqual(gaps.first?.lastError, "timeout")
        XCTAssertEqual(gaps.first?.demoted, true)
    }

    /// A ledger written before `acknowledged` existed decodes with it `nil`, and must read as
    /// "nothing acknowledged yet" — the safe direction — not as "everything captured is fine".
    func testMissingAcknowledgedFieldTreatsEverythingCapturedAsUnacknowledged() {
        let ledger = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: nil, preText: "",
            segments: [Segment(range: 0..<1000, text: "hello", source: .live)]
        )
        XCTAssertNil(ledger.acknowledged)
        XCTAssertEqual(ledger.derivedGaps(capturedUpTo: 1000).map(\.range), [0..<1000])
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

    // MARK: - folding

    /// The live write path: new segments merge with whatever batch/recovery segments the ledger
    /// already had, `acknowledged` extends rather than replaces, and gaps re-derive from the
    /// result — what the periodic ledger loop and the final synchronous fold at `stop()` are both
    /// built from, so neither can disagree with the other about what the take's last moment holds.
    func testFoldingMergesLiveSegmentsWithExistingRecoveredOnesAndExtendsAcknowledged() {
        let base = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: "s", preText: "",
            segments: [Segment(range: 8000..<9000, text: "recovered", source: .batch)],
            capturedUpTo: 9000, acknowledged: [0..<1000]
        )
        let folded = base.folding(
            liveSegments: [Segment(range: 0..<1000, text: "hello", source: .live)], capturedUpTo: 10000,
            newlyAcknowledged: [1000..<10000]
        )
        XCTAssertEqual(Set(folded.segments.map(\.range)), [0..<1000, 8000..<9000])
        XCTAssertEqual(folded.acknowledged, [0..<10000])
        XCTAssertEqual(folded.capturedUpTo, 10000)
    }

    /// The exact regression this fixes: a take's very last sentence, committed right before
    /// `stop()` returns, must show up once folded — proving the same function that folds live
    /// mid-take also folds a take's final state correctly, with nothing special-cased for "last".
    func testFoldingIncludesTheFinalSegmentAndLeavesNoGapWhenFullyAcknowledged() {
        let base = TranscriptLedger(takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: "s", preText: "")
        let final = base.folding(
            liveSegments: [
                Segment(range: 0..<8000, text: "hello", source: .live),
                Segment(range: 8000..<16000, text: "world", source: .live),
            ], capturedUpTo: 16000, newlyAcknowledged: [0..<16000]
        )
        XCTAssertEqual(VoiceTextAssembly.assembledText(from: final), "hello world")
        XCTAssertTrue(final.gaps.isEmpty)
    }

    // MARK: - applyingBackfill

    /// A gap opened *after* the pass that resolved a different gap started must survive being
    /// applied — `applyingBackfill` only ever removes the exact ranges it was told were resolved,
    /// never a blanket "whatever gaps existed when the pass began".
    func testApplyingBackfillOnlyRemovesTheRangesItResolvedNotAWholeStaleSnapshot() {
        let ledger = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: "s", preText: "",
            capturedUpTo: 10000,
            gaps: [Gap(range: 0..<1000), Gap(range: 5000..<6000, attempts: 1)]
        )
        let applied = ledger.applyingBackfill(
            newSegments: [Segment(range: 0..<1000, text: "recovered", source: .batch)],
            resolved: [0..<1000], failed: []
        )
        XCTAssertEqual(applied.gaps.map(\.range), [5000..<6000], "the untouched gap must survive, unchanged")
        XCTAssertEqual(applied.segments.map(\.text), ["recovered"])
    }

    /// A gap that grew while the pass was in flight — a later fold pushed its far edge out before
    /// this pass's result came back — used to survive completely unchanged, since the old code
    /// only removed a gap equal to `resolved`. The grown gap is now narrowed to whatever sliver
    /// past the resolved stretch is still actually uncovered, so the next pass re-requests only
    /// that sliver instead of re-transcribing words this pass already covered.
    func testApplyingBackfillNarrowsAGapThatGrewWhileThePassWasInFlightRatherThanLeavingItWhole() {
        let ledger = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: "s", preText: "",
            capturedUpTo: 32000, gaps: [Gap(range: 0..<32000, attempts: 1, lastError: "timeout")]
        )
        let applied = ledger.applyingBackfill(
            newSegments: [Segment(range: 0..<16000, text: "recovered", source: .batch)],
            resolved: [0..<16000], failed: []
        )
        XCTAssertEqual(applied.gaps.map(\.range), [16000..<32000], "only the still-uncovered sliver remains")
        XCTAssertEqual(applied.gaps.first?.attempts, 1, "the retry budget carries forward onto the narrowed gap")
        XCTAssertEqual(applied.gaps.first?.lastError, "timeout")
    }

    func testApplyingBackfillBumpsTheAttemptCountOfAFailedRangeAgainstTheCurrentGap() {
        let ledger = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: "s", preText: "",
            capturedUpTo: 10000, gaps: [Gap(range: 0..<1000, attempts: 1)]
        )
        let applied = ledger.applyingBackfill(
            newSegments: [], resolved: [], failed: [(range: 0..<1000, error: "timeout")])
        XCTAssertEqual(applied.gaps.first?.attempts, 2)
        XCTAssertEqual(applied.gaps.first?.lastError, "timeout")
    }

    /// `delivered` is deliberately untouched — only the caller who actually wrote the text
    /// somewhere knows whether it was delivered, not the arithmetic that closed the gap.
    func testApplyingBackfillNeverTouchesDelivered() {
        let ledger = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: "s", preText: "",
            capturedUpTo: 1000, gaps: [Gap(range: 0..<1000)], delivered: false
        )
        let applied = ledger.applyingBackfill(
            newSegments: [Segment(range: 0..<1000, text: "recovered", source: .batch)], resolved: [0..<1000], failed: []
        )
        XCTAssertTrue(applied.gaps.isEmpty)
        XCTAssertFalse(applied.delivered, "closing every gap must not silently mark the take delivered")
    }

    /// Without this, a gap `applyingBackfill` just healed reopens the instant the next ordinary
    /// `folding()` call runs: `folding()` recomputes `gaps` entirely fresh from `acknowledged`,
    /// which a backfill otherwise never touches, discarding the heal. A resolved range is exactly
    /// as settled a fact about the take as anything a live commit ever acknowledged — nothing
    /// about it should still count as "not yet accounted for" once it is folded again. Call mode
    /// hits this on every cycle after the first, since its own ledger loop restarts per
    /// collecting cycle: a gap healed while wake mode held no cycle open would otherwise be
    /// silently reopened the moment the next cycle's first write lands.
    func testApplyingBackfillMarksTheResolvedRangeAcknowledgedSoALaterFoldNeverReopensIt() {
        let ledger = TranscriptLedger(
            takeId: "t", mode: .microphone, sampleRate: 16000, draftKey: "s", preText: "",
            capturedUpTo: 1500, gaps: [Gap(range: 500..<1500)], acknowledged: [0..<500]
        )
        let healed = ledger.applyingBackfill(
            newSegments: [Segment(range: 500..<1500, text: "recovered", source: .batch)],
            resolved: [500..<1500], failed: []
        )
        XCTAssertTrue(healed.gaps.isEmpty)

        // The next ordinary write — no new live segments, no new acknowledgment, same bounds.
        let refolded = healed.folding(liveSegments: [], capturedUpTo: 1500, newlyAcknowledged: [])
        XCTAssertTrue(refolded.gaps.isEmpty, "a fold after a heal must not reopen the same gap")
    }
}
