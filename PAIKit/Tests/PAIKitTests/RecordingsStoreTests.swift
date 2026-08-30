import XCTest

@testable import PAIKit

/// The retention rule lives in `SettingsStore` — the list it caps is the one the settings screen
/// renders and the one that persists. These tests hold the seam between it and the audio: an
/// evicted entry's bytes must go with it, and nothing else may delete them.
@MainActor
final class RecordingsStoreTests: XCTestCase {

    private func meta(id: String) -> RecordingMeta {
        RecordingMeta(timestampMs: Double(id) ?? 0, durationMs: 1000)
    }

    private func makeSettings(_ storage: InMemorySettingsStorage) -> SettingsStore {
        let factory = try! PaiRequestFactory(baseURL: "https://example.invalid", tokenProvider: { nil })
        return SettingsStore(apiClient: PaiApiClient(requestFactory: factory), storage: storage)
    }

    func testEvictingAnEntryDeletesItsAudio() async throws {
        let audioStorage = FakeRecordingAudioStorage()
        let library = RecordingAudioLibrary(storage: audioStorage)
        let settings = makeSettings(InMemorySettingsStorage())
        settings.onRecordingEvicted = { meta in
            Task { await library.delete(id: meta.id) }
        }

        // One past the cap, so exactly one entry falls off the end.
        for index in 1...(SettingsStore.maxRecordings + 1) {
            let entry = meta(id: String(index))
            try await library.save(id: entry.id, raw: nil, sent: Data())
            settings.saveRecording(entry)
        }

        // The eviction hook hops through a Task, so wait for the effect rather than assuming it
        // has already run.
        let deadline = ContinuousClock().now + .seconds(5)
        while ContinuousClock().now < deadline {
            if await !audioStorage.deletedIds.isEmpty { break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }

        let deleted = await audioStorage.deletedIds
        XCTAssertEqual(settings.recordings.count, SettingsStore.maxRecordings)
        XCTAssertEqual(
            deleted, ["1"],
            "the oldest entry's audio must go with it — bytes cannot outlive their metadata")
    }

    func testSavingAudioDoesNotItselfKeepAList() async throws {
        // The whole point of the split: this type holds no list, so it cannot disagree with the
        // one that is displayed. Saving twelve without any metadata means twelve stored blobs and
        // no eviction, because nothing here knows about a cap.
        let audioStorage = FakeRecordingAudioStorage()
        let library = RecordingAudioLibrary(storage: audioStorage)

        for index in 1...12 {
            try await library.save(id: String(index), raw: nil, sent: Data())
        }

        let saved = await audioStorage.savedIds
        let deleted = await audioStorage.deletedIds
        XCTAssertEqual(saved.count, 12)
        XCTAssertTrue(deleted.isEmpty)
    }

    func testMetaWithOnlyRequiredFieldsRoundTripsThroughJSON() async throws {
        let minimal = RecordingMeta(timestampMs: 0, durationMs: 500)
        let data = try JSONEncoder().encode(minimal)
        let decoded = try JSONDecoder().decode(RecordingMeta.self, from: data)
        XCTAssertEqual(decoded, minimal)
        XCTAssertNil(decoded.transcript)
        XCTAssertNil(decoded.silence)
    }
}

actor FakeRecordingAudioStorage: RecordingAudioStorage {
    private(set) var savedIds: [String] = []
    private(set) var deletedIds: [String] = []

    func save(id: String, raw: Data?, sent: Data) async throws {
        savedIds.append(id)
    }

    func delete(id: String) async {
        deletedIds.append(id)
    }
}
