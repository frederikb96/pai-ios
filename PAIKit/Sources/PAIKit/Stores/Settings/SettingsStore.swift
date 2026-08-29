import Foundation
import Observation

/// STT language selection. Port of `stores/settings.ts`'s `SttLanguage`.
///
/// No `.unrecognized` fallback the way `SmtpSecurity` has one: this project has exactly one STT
/// provider and deliberately no provider-abstraction fallback branch (see `CLAUDE.md` — the
/// retired Android client's `else -> OpenAI` default is the cascading-default pattern this
/// avoids), and the same discipline applies to the language selector next to it. A value this
/// app never wrote is a bug to surface, not a value to silently coerce into `.auto`.
public enum SttLanguage: String, Codable, Sendable, CaseIterable {
    case auto, en, de
}

/// Everything the Settings screen shows and edits, minus what other layers already own:
/// **theme** (the app shell — needed before any screen including this one renders) and
/// **terminal font size** (the terminal view — the web has no Settings UI for it either; it
/// changes only by pinching inside the terminal view).
///
/// Three different persistence shapes live here, deliberately kept distinct rather than implied
/// by which method happens to get called:
/// - **client-side, immediate** — STT language, mic device, silence detection, the two
///   diagnostic lists, expand preferences: a `set...` call persists to `storage` and updates
///   published state in the same step, same as the web's `localStorage` + immediate apply.
/// - **server-persisted, draft-and-save** — `smtp`, a whole sub-store, because Save/dirty
///   tracking/validation is real state, not a detail this store should flatten away.
/// - **write-only secret** — `elevenLabsKey` (and `smtp.password`): presence is fetched, the
///   value is only ever sent, never read back. See `WriteOnlySecretField`.
@MainActor
@Observable
public final class SettingsStore {
    private enum Keys {
        static let sttLanguage = "sttLanguage"
        static let micDeviceId = "micDeviceId"
        static let silenceDetectionEnabled = "silenceDetectionEnabled"
        static let silenceThreshold = "silenceThreshold"
        static let silenceDurationMs = "silenceDurationMs"
        static let sentMessages = "sentMessages"
        static let recordings = "recordings"
        static let expandPreferences = "expandPreferences"
        static let theme = "theme"
    }

    static let maxSentMessages = 10
    static let maxRecordings = 10

    public private(set) var sttLanguage: SttLanguage
    public private(set) var micDeviceId: String
    public private(set) var silenceDetectionEnabled: Bool
    public private(set) var silenceThreshold: Double
    public private(set) var silenceDurationMs: Double
    public private(set) var sentMessages: [SentMessage]
    public private(set) var recordings: [RecordingMeta]
    /// Keyed by `ExpandPreferences.toolExpandKey`/`.systemExpandKey`. An absent key reads as
    /// `false` — see `isExpandEnabled`.
    public private(set) var expandPreferences: [String: Bool]

    /// Client-side only, like the web's. Nothing about the appearance reaches the server.
    public private(set) var theme: AppTheme

    public let elevenLabsKey: WriteOnlySecretField
    public let smtp: SmtpSettingsStore

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
        self.smtp = SmtpSettingsStore(apiClient: apiClient)

        sttLanguage = storage.value(forKey: Keys.sttLanguage) ?? .auto
        micDeviceId = storage.value(forKey: Keys.micDeviceId) ?? ""
        silenceDetectionEnabled = storage.value(forKey: Keys.silenceDetectionEnabled) ?? false
        silenceThreshold = storage.value(forKey: Keys.silenceThreshold) ?? 0.005
        silenceDurationMs = storage.value(forKey: Keys.silenceDurationMs) ?? 3000
        sentMessages = storage.value(forKey: Keys.sentMessages) ?? []
        recordings = storage.value(forKey: Keys.recordings) ?? []
        expandPreferences = storage.value(forKey: Keys.expandPreferences) ?? [:]
        theme = storage.value(forKey: Keys.theme) ?? .system
    }

    // MARK: - Client-side settings, immediate apply

    public func setTheme(_ theme: AppTheme) {
        self.theme = theme
        storage.setValue(theme, forKey: Keys.theme)
    }

    public func setSttLanguage(_ language: SttLanguage) {
        sttLanguage = language
        storage.setValue(language, forKey: Keys.sttLanguage)
    }

    public func setMicDeviceId(_ deviceId: String) {
        micDeviceId = deviceId
        storage.setValue(deviceId, forKey: Keys.micDeviceId)
    }

    public func setSilenceDetectionEnabled(_ enabled: Bool) {
        silenceDetectionEnabled = enabled
        storage.setValue(enabled, forKey: Keys.silenceDetectionEnabled)
    }

    public func setSilenceThreshold(_ threshold: Double) {
        silenceThreshold = threshold
        storage.setValue(threshold, forKey: Keys.silenceThreshold)
    }

    public func setSilenceDurationMs(_ ms: Double) {
        silenceDurationMs = ms
        storage.setValue(ms, forKey: Keys.silenceDurationMs)
    }

    // MARK: - Expand preferences

    public func isExpandEnabled(_ key: String) -> Bool {
        expandPreferences[key] ?? false
    }

    public func setExpandPreference(_ key: String, enabled: Bool) {
        expandPreferences[key] = enabled
        storage.setValue(expandPreferences, forKey: Keys.expandPreferences)
    }

    // MARK: - Diagnostic lists

    public func saveSentMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let entry = SentMessage(text: text, timestampMs: Date().timeIntervalSince1970 * 1000)
        sentMessages = Array(([entry] + sentMessages).prefix(Self.maxSentMessages))
        storage.setValue(sentMessages, forKey: Keys.sentMessages)
    }

    public func saveRecording(_ meta: RecordingMeta) {
        let all = [meta] + recordings
        let kept = Array(all.prefix(Self.maxRecordings))
        let evicted = all.dropFirst(Self.maxRecordings)
        recordings = kept
        storage.setValue(recordings, forKey: Keys.recordings)
        for entry in evicted {
            onRecordingEvicted?(entry)
        }
    }

    // MARK: - Secret presence (fetch before Settings is ever opened)

    /// Populates `elevenLabsKey.status` and `smtp.password.status` from one presence fetch.
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
            elevenLabsKey.applyStatus(statuses.elevenlabs)
            smtp.password.applyStatus(statuses.smtpPassword)
        } catch {
            // Presence stays `nil` (unknown) rather than being guessed at — a gate reading
            // `nil` the same as "not set" degrades to the safe, if unhelpful, state rather than
            // claiming a key is configured when the fetch never confirmed it.
        }
    }
}
