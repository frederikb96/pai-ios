import Foundation
import Observation

/// Where a recording's bytes actually live — deliberately not this package's concern. Writing
/// files is not Apple-only, but *where* (`FileManager.default.urls(for:in:)`'s sandbox
/// directories) is a real-device concept this package cannot exercise on Linux, and every other
/// boundary in this file draws the same line: `RecordingsStore` owns the list, retention and
/// metadata — provably, in a unit test — and the app supplies a concrete `RecordingAudioStorage`
/// that actually touches disk.
public protocol RecordingAudioStorage: Sendable {
    func save(id: String, raw: Data?, sent: Data) async throws
    func delete(id: String) async
}

/// Past recordings are strictly client-local — there is no backend recordings route, on the web
/// or here, so this list starts empty on every install and never syncs. Say so in the UI, or an
/// empty list on a fresh device reads as a sync bug rather than the expected state.
@MainActor
@Observable
public final class RecordingsStore {
    /// `MAX_RECORDINGS` — the web's cap, no time-based expiry alongside it.
    public static let maxRecordings = 10

    /// Newest first, matching the web's insertion order.
    public private(set) var recordings: [RecordingMeta]

    private let storage: RecordingAudioStorage

    public init(storage: RecordingAudioStorage, initial: [RecordingMeta] = []) {
        self.storage = storage
        self.recordings = initial
    }

    /// Saves a new recording and evicts down to `maxRecordings`, deleting each evicted entry's
    /// stored audio so nothing is ever orphaned on disk. `raw` is `nil` when nothing was kept —
    /// `RecordingMeta.rawStored` should already say so, and this does not second-guess it.
    public func add(_ meta: RecordingMeta, raw: Data?, sent: Data) async throws {
        try await storage.save(id: meta.id, raw: raw, sent: sent)
        recordings.insert(meta, at: 0)
        while recordings.count > Self.maxRecordings {
            let evicted = recordings.removeLast()
            await storage.delete(id: evicted.id)
        }
    }

    public func remove(id: String) async {
        recordings.removeAll { $0.id == id }
        await storage.delete(id: id)
    }
}
