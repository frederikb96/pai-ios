import XCTest

@testable import PAIKit

/// Records every call it receives, in order, so a test can assert not just the final list but
/// that the eviction path actually reached storage — the fixture-invocation gap `unit-tests`
/// warns about, where a store's own list looking right says nothing about whether the delete
/// underneath it ever ran.
private final class FakeRecordingAudioStorage: RecordingAudioStorage, @unchecked Sendable {
    private(set) var savedIds: [String] = []
    private(set) var deletedIds: [String] = []

    func save(id: String, raw: Data?, sent: Data) async throws {
        savedIds.append(id)
    }

    func delete(id: String) async {
        deletedIds.append(id)
    }
}

@MainActor
final class RecordingsStoreTests: XCTestCase {

    /// Identity comes from the timestamp, so a test that wants a particular id sets that.
    private func meta(id: String) -> RecordingMeta {
        RecordingMeta(timestampMs: Double(id) ?? 0, durationMs: 1000)
    }

    func testAddingWithinCapacityKeepsEveryRecording() async throws {
        let storage = FakeRecordingAudioStorage()
        let store = RecordingsStore(storage: storage)

        for index in 0..<5 {
            try await store.add(meta(id: "\(index)"), raw: nil, sent: Data())
        }

        XCTAssertEqual(store.recordings.count, 5)
        XCTAssertEqual(storage.deletedIds, [])
    }

    /// The eleventh recording must evict the oldest (index "0", inserted first, now furthest
    /// from the front since every add inserts at position 0) — asserting only `count == 10`
    /// would pass even if the wrong entry were evicted.
    func testAddingPastCapacityEvictsTheOldestAndDeletesItsStorage() async throws {
        let storage = FakeRecordingAudioStorage()
        let store = RecordingsStore(storage: storage)

        for index in 0..<(RecordingsStore.maxRecordings + 1) {
            try await store.add(meta(id: "\(index)"), raw: nil, sent: Data())
        }

        XCTAssertEqual(store.recordings.count, RecordingsStore.maxRecordings)
        XCTAssertFalse(store.recordings.contains { $0.id == "0" })
        XCTAssertEqual(storage.deletedIds, ["0"])
    }

    func testNewestRecordingIsFirstInTheList() async throws {
        let storage = FakeRecordingAudioStorage()
        let store = RecordingsStore(storage: storage)

        try await store.add(meta(id: "100"), raw: nil, sent: Data())
        try await store.add(meta(id: "200"), raw: nil, sent: Data())

        XCTAssertEqual(store.recordings.first?.id, "200")
    }

    func testRemovingDeletesFromTheListAndFromStorage() async throws {
        let storage = FakeRecordingAudioStorage()
        let store = RecordingsStore(storage: storage)
        try await store.add(meta(id: "42"), raw: nil, sent: Data())

        await store.remove(id: "42")

        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertEqual(storage.deletedIds, ["42"])
    }

    /// Every field past `durationMs` is optional by design — an entry decoded with none of them
    /// set (an old recording from a version that did not record levels, say) must still decode
    /// rather than fail the whole list.
    func testMetaWithOnlyRequiredFieldsRoundTripsThroughJSON() throws {
        let minimal = RecordingMeta(timestampMs: 0, durationMs: 500)
        let data = try JSONEncoder().encode(minimal)
        let decoded = try JSONDecoder().decode(RecordingMeta.self, from: data)
        XCTAssertEqual(decoded, minimal)
        XCTAssertNil(decoded.transcript)
        XCTAssertNil(decoded.silence)
    }
}
