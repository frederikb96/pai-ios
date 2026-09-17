import XCTest

@testable import PAIKit

@MainActor
final class WakeWordSampleStoreTests: XCTestCase {

    private func sample(_ id: String) -> WakeWordSample {
        WakeWordSample(
            id: id, kind: .positive, label: "run", fileName: "\(id).wav", recordedAtMs: 0, durationMs: 800,
            sampleRate: 48000, microphoneRoute: "iPhone Microphone")
    }

    func testAddPersistsAcrossAFreshInstanceOnTheSameStorage() async throws {
        let storage = SettingsInMemoryKeyValueStore()
        let store = WakeWordSampleStore(storage: storage)
        store.add(sample("a"))

        let reloaded = WakeWordSampleStore(storage: storage)
        XCTAssertEqual(reloaded.samples.map(\.id), ["a"])
    }

    func testRemoveDeletesOnlyTheMatchingEntryAndPersists() async throws {
        let storage = SettingsInMemoryKeyValueStore()
        let store = WakeWordSampleStore(storage: storage)
        store.add(sample("a"))
        store.add(sample("b"))
        var removed: [String] = []
        store.onSampleRemoved = { removed.append($0.id) }

        store.remove(id: "a")

        XCTAssertEqual(store.samples.map(\.id), ["b"])
        XCTAssertEqual(removed, ["a"])
        let reloaded = WakeWordSampleStore(storage: storage)
        XCTAssertEqual(reloaded.samples.map(\.id), ["b"])
    }

    func testRemoveOfUnknownIdIsANoOp() async throws {
        let storage = SettingsInMemoryKeyValueStore()
        let store = WakeWordSampleStore(storage: storage)
        store.add(sample("a"))
        var firedCount = 0
        store.onSampleRemoved = { _ in firedCount += 1 }

        store.remove(id: "does-not-exist")

        XCTAssertEqual(store.samples.map(\.id), ["a"])
        XCTAssertEqual(firedCount, 0)
    }

    /// Three entries, not one — the minimum that can tell "fired once per entry" apart from
    /// "fired once, for the whole batch".
    func testClearAllFiresOnSampleRemovedOncePerEntryAndPersistsEmpty() async throws {
        let storage = SettingsInMemoryKeyValueStore()
        let store = WakeWordSampleStore(storage: storage)
        store.add(sample("a"))
        store.add(sample("b"))
        store.add(sample("c"))
        var removed: [String] = []
        store.onSampleRemoved = { removed.append($0.id) }

        store.clearAll()

        XCTAssertTrue(store.samples.isEmpty)
        XCTAssertEqual(removed, ["a", "b", "c"])
        let reloaded = WakeWordSampleStore(storage: storage)
        XCTAssertTrue(reloaded.samples.isEmpty)
    }
}
