import XCTest

@testable import PAIKit

final class RecordingReconciliationTests: XCTestCase {

    // MARK: - orphanedIds

    func testOrphanedIdsIsWhatsOnDiskAndNotInKnown() {
        let orphans = RecordingReconciliation.orphanedIds(onDisk: ["1", "2", "3"], known: ["2"])
        XCTAssertEqual(orphans, ["1", "3"])
    }

    func testOrphanedIdsIsEmptyWhenEverythingOnDiskIsAlreadyKnown() {
        let orphans = RecordingReconciliation.orphanedIds(onDisk: ["1", "2"], known: ["1", "2", "3"])
        XCTAssertTrue(orphans.isEmpty)
    }

    // MARK: - metadata(for:)

    /// The core disaster-recovery property: a take on disk with no metadata gets one, tagged so
    /// it reads as recovered.
    func testProducesCrashTaggedMetadataForARealTake() throws {
        // 24000 Hz, 16-bit mono: one second of audio is 48000 bytes.
        let take = RecordingReconciliation.OrphanedTake(
            id: "1700000000000", sampleRate: 24000, dataSize: 48000, rawStored: true)
        let meta = RecordingReconciliation.metadata(for: take)
        XCTAssertEqual(meta?.id, "1700000000000")
        XCTAssertEqual(meta?.timestampMs, 1_700_000_000_000)
        XCTAssertEqual(try XCTUnwrap(meta?.durationMs), 1000, accuracy: 0.001)
        XCTAssertEqual(meta?.sampleRate, 24000)
        XCTAssertEqual(meta?.rawStored, true)
        XCTAssertEqual(meta?.endedBy, .crashed)
    }

    func testRawStoredFalseWhenNoRawFileAccompaniedTheOrphan() {
        let take = RecordingReconciliation.OrphanedTake(
            id: "1000", sampleRate: 16000, dataSize: 32000, rawStored: false)
        XCTAssertEqual(RecordingReconciliation.metadata(for: take)?.rawStored, false)
    }

    /// The mirror of `persistRecording()`'s own `guard sent?.hasData == true` — a `start()` stub
    /// the process died before ever appending to must not become a misleading zero-second row.
    func testNilForATakeWithNoAudioEverAppended() {
        let take = RecordingReconciliation.OrphanedTake(id: "1000", sampleRate: 24000, dataSize: 0, rawStored: false)
        XCTAssertNil(RecordingReconciliation.metadata(for: take))
    }

    func testNilForAZeroSampleRateHeader() {
        let take = RecordingReconciliation.OrphanedTake(id: "1000", sampleRate: 0, dataSize: 48000, rawStored: false)
        XCTAssertNil(RecordingReconciliation.metadata(for: take))
    }

    /// A filename that survived some other corruption and does not parse back to a real
    /// timestamp must not be surfaced as a recording dated the Unix epoch.
    func testNilForAnIdThatIsNotANumericTimestamp() {
        let take = RecordingReconciliation.OrphanedTake(
            id: "not-a-timestamp", sampleRate: 24000, dataSize: 48000, rawStored: false)
        XCTAssertNil(RecordingReconciliation.metadata(for: take))
    }

    func testNilForAZeroIdTimestamp() {
        let take = RecordingReconciliation.OrphanedTake(id: "0", sampleRate: 24000, dataSize: 48000, rawStored: false)
        XCTAssertNil(RecordingReconciliation.metadata(for: take))
    }

    // MARK: - reconcile(ledger:takeId:sampleRate:capturedSampleCount:)

    /// A take found on disk with no ledger at all — an app version predating this design, or a
    /// kill before the very first segment landed. Nothing is covered, so the whole captured range
    /// becomes one gap.
    func testReconcileWithNoLedgerTurnsAllCapturedAudioIntoOneGap() {
        let reconciled = RecordingReconciliation.reconcile(
            ledger: nil, takeId: "1700000000000", sampleRate: 16000, capturedSampleCount: 48000
        )
        XCTAssertEqual(reconciled.mode, .microphone)
        XCTAssertEqual(reconciled.capturedUpTo, 48000)
        XCTAssertEqual(reconciled.gaps.map(\.range), [0..<48000])
    }

    /// A ledger whose last segment stops short of what was actually captured — the crash caught
    /// audio arriving after the last committed segment. The attempt count on a gap that already
    /// existed there must survive the reconciliation rather than reset to zero.
    func testReconcilePreservesAttemptCountsOnAGapThatStillOverlaps() {
        let ledger = TranscriptLedger(
            takeId: "1700000000001", mode: .microphone, sampleRate: 16000, draftKey: "session-1", preText: "",
            segments: [Segment(range: 0..<16000, text: "hello", source: .live)], capturedUpTo: 32000,
            gaps: [Gap(range: 16000..<32000, attempts: 2, lastError: "timeout")]
        )
        let reconciled = RecordingReconciliation.reconcile(
            ledger: ledger, takeId: ledger.takeId, sampleRate: 16000, capturedSampleCount: 48000
        )
        XCTAssertEqual(reconciled.capturedUpTo, 48000)
        XCTAssertEqual(reconciled.gaps.count, 1)
        XCTAssertEqual(reconciled.gaps.first?.range, 16000..<48000)
        XCTAssertEqual(reconciled.gaps.first?.attempts, 2)
        XCTAssertEqual(reconciled.gaps.first?.lastError, "timeout")
    }

    /// A ledger whose gaps are already fully covered by later segments must reconcile to no gaps
    /// at all — recovery does not resurrect work that has already been done.
    func testReconcileDropsAGapAlreadyFullyCovered() {
        let ledger = TranscriptLedger(
            takeId: "1700000000002", mode: .microphone, sampleRate: 16000, draftKey: nil, preText: "",
            segments: [Segment(range: 0..<32000, text: "all of it", source: .live)], capturedUpTo: 32000
        )
        let reconciled = RecordingReconciliation.reconcile(
            ledger: ledger, takeId: ledger.takeId, sampleRate: 16000, capturedSampleCount: 32000
        )
        XCTAssertTrue(reconciled.gaps.isEmpty)
    }
}
