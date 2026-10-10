import Foundation
import Observation

/// Everything the Settings screen shows and edits, minus what other layers already own:
/// **theme** (the app shell — needed before any screen including this one renders) and
/// **terminal font size** (the terminal view — the web has no Settings UI for it either; it
/// changes only by pinching inside the terminal view).
///
/// Three different persistence shapes live here, deliberately kept distinct rather than implied
/// by which method happens to get called:
/// - **client-side, immediate** — mic device, the silence gate, the two diagnostic lists, expand
///   preferences: a `set...` call persists to `storage` and updates published state in the same
///   step, same as the web's `localStorage` + immediate apply.
/// - **server-persisted, draft-and-save** — `smtp`, a whole sub-store, because Save/dirty
///   tracking/validation is real state, not a detail this store should flatten away.
/// - **write-only secret** — `elevenLabsKey`, `homeAssistantToken`, `todoistToken` (and
///   `smtp.password`): presence is fetched, the value is only ever sent, never read back. See
///   `WriteOnlySecretField`.
@MainActor
@Observable
public final class SettingsStore {
    private enum Keys {
        static let silenceGate = "silenceGate"
        static let micDeviceId = "micDeviceId"
        static let sentMessages = "sentMessages"
        static let recordings = "recordings"
        static let theme = "theme"
        static let showsNoteLineNumbers = "showsNoteLineNumbers"
        static let noteToolbarLayout = "noteToolbarLayout"
    }

    static let maxSentMessages = 10
    static let maxRecordings = 10

    /// Client-local and never synced: the threshold is a property of this phone's microphones.
    public private(set) var silenceGate: SilenceGateSettings
    public private(set) var micDeviceId: String
    public private(set) var sentMessages: [SentMessage]
    public private(set) var recordings: [RecordingMeta]
    /// Client-side only, like the web's. Nothing about the appearance reaches the server.
    public private(set) var theme: AppTheme
    /// The note editor's line-number gutter — off by default, since most notes are short enough
    /// that Obsidian's own gutter is a taste rather than a need.
    public private(set) var showsNoteLineNumbers: Bool
    /// The note editor's formatting bar: which actions it offers, and in which order. Stored as
    /// raw strings rather than `[NoteToolbarActionId]` directly — decoding straight into the enum
    /// array would fail the whole array the moment one id is unrecognised, which is exactly the
    /// "silently wipes the arrangement" failure ``NoteToolbarLayout/sanitize(rawIds:)`` exists to
    /// avoid. Always sanitized before being stored here, so every read of this property is safe
    /// to hand straight to the bar with no further checking.
    public private(set) var noteToolbarLayout: [NoteToolbarActionId]

    public let elevenLabsKey: WriteOnlySecretField
    /// The two third-party credentials Computer presents itself. Set here rather than deployed
    /// with the pod, so changing either needs no release.
    public let homeAssistantToken: WriteOnlySecretField
    public let todoistToken: WriteOnlySecretField
    public let smtp: SmtpSettingsStore
    public let alerts: AlertsStore
    public let voices: SpokenVoiceSettingsStore

    /// Called for a recording evicted by the 10-entry cap, so whichever store holds the actual
    /// audio (a voice-capture concern, not this one's) can delete it — the same seam the web's
    /// `saveRecording` closes with a direct `deleteAudioData` call this store cannot make
    /// itself, having no audio storage of its own. Not `@Sendable`: `SettingsStore` is
    /// `@MainActor`, and `saveRecording` invokes this synchronously in that same isolation
    /// rather than handing it across a concurrency boundary.
    public var onRecordingEvicted: ((RecordingMeta) -> Void)?

    private let apiClient: PaiApiClient
    private let storage: SettingsKeyValueStore

    public init(apiClient: PaiApiClient, storage: SettingsKeyValueStore) {
        self.apiClient = apiClient
        self.storage = storage
        self.elevenLabsKey = WriteOnlySecretField(name: .elevenlabs, apiClient: apiClient)
        self.homeAssistantToken = WriteOnlySecretField(
            name: .homeAssistantToken, apiClient: apiClient)
        self.todoistToken = WriteOnlySecretField(name: .todoistToken, apiClient: apiClient)
        self.smtp = SmtpSettingsStore(apiClient: apiClient)
        self.alerts = AlertsStore(api: apiClient)
        self.voices = SpokenVoiceSettingsStore(apiClient: apiClient)

        silenceGate = storage.value(forKey: Keys.silenceGate) ?? .standard
        micDeviceId = storage.value(forKey: Keys.micDeviceId) ?? ""
        sentMessages = storage.value(forKey: Keys.sentMessages) ?? []
        recordings = storage.value(forKey: Keys.recordings) ?? []
        theme = storage.value(forKey: Keys.theme) ?? .system
        showsNoteLineNumbers = storage.value(forKey: Keys.showsNoteLineNumbers) ?? false
        let storedToolbarIds: [String] = storage.value(forKey: Keys.noteToolbarLayout) ?? []
        noteToolbarLayout = NoteToolbarLayout.sanitize(rawIds: storedToolbarIds)
    }

    // MARK: - Client-side settings, immediate apply

    public func setTheme(_ theme: AppTheme) {
        self.theme = theme
        storage.setValue(theme, forKey: Keys.theme)
    }

    public func setSilenceGate(_ settings: SilenceGateSettings) {
        var clamped = settings
        clamped.manualThresholdDb = min(
            max(settings.manualThresholdDb, SilenceGateSettings.manualRange.lowerBound),
            SilenceGateSettings.manualRange.upperBound)
        silenceGate = clamped
        storage.setValue(clamped, forKey: Keys.silenceGate)
    }

    public func setMicDeviceId(_ deviceId: String) {
        micDeviceId = deviceId
        storage.setValue(deviceId, forKey: Keys.micDeviceId)
    }

    public func setShowsNoteLineNumbers(_ enabled: Bool) {
        showsNoteLineNumbers = enabled
        storage.setValue(enabled, forKey: Keys.showsNoteLineNumbers)
    }

    /// Re-sanitized before being kept, so a caller handing back a layout with a duplicate or an
    /// id this build has never heard of can't get it into `noteToolbarLayout` unfiltered.
    public func setNoteToolbarLayout(_ layout: [NoteToolbarActionId]) {
        let sanitized = NoteToolbarLayout.sanitize(rawIds: layout.map(\.rawValue))
        noteToolbarLayout = sanitized
        storage.setValue(sanitized.map(\.rawValue), forKey: Keys.noteToolbarLayout)
    }

    // MARK: - Diagnostic lists

    public func saveSentMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let entry = SentMessage(text: text, timestampMs: Date().timeIntervalSince1970 * 1000)
        sentMessages = Array(([entry] + sentMessages).prefix(Self.maxSentMessages))
        storage.setValue(sentMessages, forKey: Keys.sentMessages)
    }

    /// Keeps the newest ten *evictable* recordings and every recording that is not — an open gap
    /// or undelivered text — whatever their count. `all` is newest-first, so counting only the
    /// evictable ones as we walk it and cutting once that count passes the cap evicts the oldest
    /// evictable entries, exactly the FIFO behaviour the flat cap used to give every recording;
    /// the durable pipeline's own rule (`TranscriptLedger.mayBeDeleted`) is just applied per entry
    /// first now, since deleting a take's only copy of not-yet-backfilled audio is the one thing
    /// this whole feature exists to stop happening again.
    public func saveRecording(_ meta: RecordingMeta) {
        let all = [meta] + recordings
        var kept: [RecordingMeta] = []
        var evicted: [RecordingMeta] = []
        var evictableSeen = 0
        for entry in all {
            guard Self.mayEvict(entry) else {
                kept.append(entry)
                continue
            }
            evictableSeen += 1
            if evictableSeen <= Self.maxRecordings {
                kept.append(entry)
            } else {
                evicted.append(entry)
            }
        }
        recordings = kept
        storage.setValue(recordings, forKey: Keys.recordings)
        for entry in evicted {
            onRecordingEvicted?(entry)
        }
    }

    /// A recording made before the durable pipeline existed carries no `transcription` at all —
    /// its `transcript` field was already the whole story, so it is evictable exactly as it always
    /// was. One tracked by the pipeline is evictable only once it agrees with
    /// `TranscriptLedger.mayBeDeleted`: no open gap, and its text already reached the draft.
    private static func mayEvict(_ meta: RecordingMeta) -> Bool {
        guard let transcription = meta.transcription else { return true }
        return transcription.gapCount == 0 && transcription.delivered
    }

    /// Replaces an already-saved recording's metadata in place — the durable pipeline updating a
    /// take's coverage as a backfill fills in its gaps, never adding a new entry (that's
    /// `saveRecording`'s job) and never disturbing the entry's position in the list.
    public func updateRecording(_ meta: RecordingMeta) {
        guard let index = recordings.firstIndex(where: { $0.id == meta.id }) else { return }
        recordings[index] = meta
        storage.setValue(recordings, forKey: Keys.recordings)
    }

    /// Removes one recording by id — the user's own Delete in the recordings screen, distinct from
    /// the cap's automatic eviction above, though both end by calling `onRecordingEvicted`, since
    /// either way the actual bytes still have to go with it.
    public func removeRecording(id: String) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        let removed = recordings.remove(at: index)
        storage.setValue(recordings, forKey: Keys.recordings)
        onRecordingEvicted?(removed)
    }

    // MARK: - Secret presence (fetch before Settings is ever opened)

    /// Populates every `WriteOnlySecretField`'s status from one presence fetch.
    ///
    /// 🚨 **The app target must call this once at launch**, before Settings has ever been
    /// opened — not on first navigation into the Settings screen. `SecretStatus` starts `nil`
    /// (unknown) on every `WriteOnlySecretField`, and a voice/composer gate that treats "unknown"
    /// the same as "not configured" refuses on a cold start with no explanation if this is only
    /// called when Settings opens. The natural place is wherever `AppEnvironment` performs its
    /// other startup fetches, since `SettingsStore` is constructed once and injected there.
    public func refreshSecretPresence() async {
        do {
            let statuses = try await apiClient.getSecretStatuses()
            for field in [elevenLabsKey, homeAssistantToken, todoistToken, smtp.password] {
                field.applyStatus(statuses.status(for: field.name))
            }
        } catch {
            // Presence stays `nil` (unknown) rather than being guessed at — a gate reading
            // `nil` the same as "not set" degrades to the safe, if unhelpful, state rather than
            // claiming a key is configured when the fetch never confirmed it.
        }
    }
}
