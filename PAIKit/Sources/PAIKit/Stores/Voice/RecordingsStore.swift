import Foundation

/// Where a recording's bytes actually live — deliberately not this package's concern. Writing
/// files is not Apple-only, but *where* (`FileManager.default.urls(for:in:)`'s sandbox
/// directories) is a real-device concept this package cannot exercise on Linux, so the app
/// supplies a concrete implementation that touches disk.
public protocol RecordingAudioStorage: Sendable {
    func save(id: String, raw: Data?, sent: Data) async throws
    func delete(id: String) async
}

/// The audio behind past recordings, and nothing else.
///
/// **`SettingsStore` owns the list** — which recordings exist, their metadata, and the retention
/// cap — because that is the list the settings screen displays and the one that persists. This
/// type owns only the bytes, and learns that an entry is gone through
/// `SettingsStore.onRecordingEvicted`.
///
/// Splitting it this way is the point: a second list with its own cap agrees with the first only
/// until one of the two caps changes, and the copy nobody renders is the copy that goes wrong
/// unnoticed.
///
/// Past recordings are strictly client-local — there is no backend route for them, on the web or
/// here — so a fresh install starts empty and never syncs. Say so in the UI, or an empty list
/// reads as a sync failure rather than the expected state.
@MainActor
public final class RecordingAudioLibrary {

    private let storage: RecordingAudioStorage

    public init(storage: RecordingAudioStorage) {
        self.storage = storage
    }

    /// `raw` is `nil` when the untouched capture could not be kept. `RecordingMeta.rawStored`
    /// already records that, and this does not second-guess it.
    public func save(id: String, raw: Data?, sent: Data) async throws {
        try await storage.save(id: id, raw: raw, sent: sent)
    }

    public func delete(id: String) async {
        await storage.delete(id: id)
    }
}
