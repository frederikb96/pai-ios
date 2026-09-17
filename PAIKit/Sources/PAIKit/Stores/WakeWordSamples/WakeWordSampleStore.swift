import Foundation
import Observation

/// The metadata list behind the wake-word sample screen — persisted client-side only, exactly
/// like `SettingsStore.recordings`: there is no backend route for this, on the web or here, and a
/// fresh install starts empty.
///
/// Mirrors the split `SettingsStore`/`RecordingAudioLibrary` already use for Past Recordings: this
/// type owns the list, never the bytes. `onSampleRemoved` is where the app-target layer deletes a
/// take's WAV file once it is gone from here — a second list with its own idea of what still
/// exists is the copy that goes wrong unnoticed.
///
/// Unlike Past Recordings, there is no retention cap: these are deliberately kept until Freddy
/// exports and clears them himself (`WakeWordSampleScreen`), since an automatic eviction would be
/// throwing away training data nobody has said is safe to lose yet.
@MainActor
@Observable
public final class WakeWordSampleStore {
    private enum Keys {
        static let samples = "wakeWordSamples"
    }

    public private(set) var samples: [WakeWordSample]

    /// Fired once per sample this store no longer lists — a `remove(id:)` or a `clearAll()` alike
    /// — so the app-target layer that owns the WAV bytes can delete exactly what this store just
    /// forgot, and nothing else.
    public var onSampleRemoved: ((WakeWordSample) -> Void)?

    private let storage: SettingsKeyValueStore

    public init(storage: SettingsKeyValueStore) {
        self.storage = storage
        samples = storage.value(forKey: Keys.samples) ?? []
    }

    /// Appended, never inserted or sorted — a run's takes already arrive in recording order, and
    /// two runs interleave only by when each was recorded, which appending already preserves.
    public func add(_ sample: WakeWordSample) {
        samples.append(sample)
        persist()
    }

    public func remove(id: String) {
        guard let index = samples.firstIndex(where: { $0.id == id }) else { return }
        let removed = samples.remove(at: index)
        persist()
        onSampleRemoved?(removed)
    }

    /// Freddy's own "I've exported these, start the next batch fresh" — every sample this store
    /// currently lists is forgotten and `onSampleRemoved` fires once per entry, same as a manual
    /// `remove(id:)`, so the audio follows exactly as it would one at a time.
    public func clearAll() {
        let removed = samples
        samples = []
        persist()
        for sample in removed { onSampleRemoved?(sample) }
    }

    private func persist() {
        storage.setValue(samples, forKey: Keys.samples)
    }
}
