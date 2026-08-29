import Foundation
import Observation

/// One past recording's metadata. Every field past `durationMs` is optional by design, mirroring
/// the web's `RecordingMeta`: an old entry decoded on a later app version must still open, and
/// nothing here is ever re-derived from another field, so there is no "optional because it can
/// be computed" case to special-case.
public struct RecordingMeta: Sendable, Equatable, Codable, Identifiable {
    /// The recording's own timestamp, matching the web's IndexedDB key — stable identity that
    /// does not depend on list position, which changes every time a newer recording is added.
    public var id: String
    public var timestampMs: Int
    public var durationMs: Int
    public var sampleRate: Int?
    public var rawSampleRate: Int?
    /// `false` when the raw capture was dropped (quota pressure, or the `RAW_BUDGET_BYTES` cap
    /// mid-take) and only the sent (already-converted) audio survives.
    public var rawStored: Bool
    public var endedBy: RecordingEndReason?
    public var silenceDetectionEnabled: Bool?
    public var silenceThreshold: Double?
    public var silenceDurationMs: Int?
    public var silenceTriggered: Bool?
    public var transcript: String?
    public var narrowband: Bool?
    public var mutedMs: Int?

    public init(
        id: String,
        timestampMs: Int,
        durationMs: Int,
        sampleRate: Int? = nil,
        rawSampleRate: Int? = nil,
        rawStored: Bool = false,
        endedBy: RecordingEndReason? = nil,
        silenceDetectionEnabled: Bool? = nil,
        silenceThreshold: Double? = nil,
        silenceDurationMs: Int? = nil,
        silenceTriggered: Bool? = nil,
        transcript: String? = nil,
        narrowband: Bool? = nil,
        mutedMs: Int? = nil
    ) {
        self.id = id
        self.timestampMs = timestampMs
        self.durationMs = durationMs
        self.sampleRate = sampleRate
        self.rawSampleRate = rawSampleRate
        self.rawStored = rawStored
        self.endedBy = endedBy
        self.silenceDetectionEnabled = silenceDetectionEnabled
        self.silenceThreshold = silenceThreshold
        self.silenceDurationMs = silenceDurationMs
        self.silenceTriggered = silenceTriggered
        self.transcript = transcript
        self.narrowband = narrowband
        self.mutedMs = mutedMs
    }
}

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
