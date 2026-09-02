import Foundation

/// What a crash-orphaned take on disk needs before it is a `RecordingMeta` the picker can show.
///
/// Pure decision logic — deliberately knows nothing about `FileManager` or where the Recordings
/// directory lives, so it is provable on Linux. `VoiceRecorderController.reconcileOrphanedRecordings()`
/// is the app-target caller that actually walks the directory, reads each candidate's header
/// through `WavHeaderReader`, and feeds this what it found.
///
/// **Why this exists at all**: `SettingsStore.saveRecording` — the only thing that ever adds an
/// entry to the list the picker renders — is called from exactly one place,
/// `VoiceRecorderController.persistRecording()`, which itself only ever runs from in-process code
/// paths (the user tapping stop, silence detection, a give-up branch). A hard kill — force-quit,
/// an OS kill under memory pressure, a dead battery — reaches none of them, so the take's WAV file
/// is complete and playable on disk while the app has no record it exists. This is the one thing
/// that goes looking on disk for what the metadata list never learned about.
public enum RecordingReconciliation {
    /// One take found on disk with no matching `RecordingMeta` — the shape a caller hands back
    /// after reading a `-sent.wav` header for every id `SettingsStore.recordings` doesn't already
    /// know.
    public struct OrphanedTake: Equatable, Sendable {
        public let id: String
        public let sampleRate: Int
        /// Bytes declared in the `data` chunk — the WAV header's own live count, rewritten after
        /// every append, so this reflects what actually reached disk rather than what the take
        /// was meant to produce.
        public let dataSize: UInt32
        public let rawStored: Bool

        public init(id: String, sampleRate: Int, dataSize: UInt32, rawStored: Bool) {
            self.id = id
            self.sampleRate = sampleRate
            self.dataSize = dataSize
            self.rawStored = rawStored
        }
    }

    /// Which ids on disk have no matching entry in `known` — everything a startup pass needs to
    /// synthesize metadata for. Order is the caller's concern, not this function's.
    public static func orphanedIds(onDisk: Set<String>, known: Set<String>) -> Set<String> {
        onDisk.subtracting(known)
    }

    /// Turns one orphaned take's raw WAV header into the `RecordingMeta` the picker renders,
    /// tagged `.crashed` so the row reads as recovered rather than an ordinary take.
    ///
    /// `nil` for a take with no audio in it — the mirror of `persistRecording()`'s own
    /// `guard result.durationMs > 0, sent?.hasData == true`: `start()` opens both files before
    /// the first sample arrives, so a take that crashed before appending anything (or whose id is
    /// not a real timestamp) leaves a 44-byte stub behind. That stub is real, on disk, and must
    /// never be deleted by a startup pass — it is simply not a recording worth surfacing, so it
    /// is left alone and unindexed rather than turned into a misleading zero-second row.
    public static func metadata(for take: OrphanedTake) -> RecordingMeta? {
        guard take.dataSize > 0, take.sampleRate > 0, let timestampMs = Double(take.id), timestampMs > 0
        else { return nil }
        let durationMs = Double(take.dataSize) / 2.0 / Double(take.sampleRate) * 1000.0
        return RecordingMeta(
            timestampMs: timestampMs,
            durationMs: durationMs,
            sampleRate: Double(take.sampleRate),
            rawStored: take.rawStored,
            endedBy: .crashed
        )
    }
}
