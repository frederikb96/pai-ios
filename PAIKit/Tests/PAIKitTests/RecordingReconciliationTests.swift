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
}
