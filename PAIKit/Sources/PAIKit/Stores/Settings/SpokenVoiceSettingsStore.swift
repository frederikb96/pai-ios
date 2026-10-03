import Foundation
import Observation

/// A text-field-friendly mirror of `SpokenVoiceSettings`' voice-group fields.
///
/// Text fields are plain `String`s — the speeds included, so a half-typed number is a state the
/// input can be in rather than a save that silently rounds it — and key terms are one
/// comma-separated line. The empty-string/`nil`, string/`Double` and line/list translations
/// happen once, at the edges (`init(loaded:)`, `asUpdate()`), rather than at every call site.
/// Same shape as `SmtpSettingsDraft`.
public struct SpokenVoiceSettingsDraft: Sendable, Equatable {
    public var computerVoice: String
    public var computerDelivery: String
    public var computerSpeed: String
    public var callVoiceId: String
    public var callSpeed: String
    public var sttKeyterms: String
    public var sttLanguage: String
    public var sttNoVerbatim: Bool

    public init(loaded: SpokenVoiceSettings) {
        computerVoice = loaded.computerVoice ?? ""
        computerDelivery = loaded.computerDelivery ?? ""
        computerSpeed = loaded.computerSpeed.map(Self.format) ?? ""
        callVoiceId = loaded.callVoiceId ?? ""
        callSpeed = Self.format(loaded.callSpeed)
        sttKeyterms = loaded.sttKeyterms.joined(separator: ", ")
        sttLanguage = loaded.sttLanguage ?? ""
        sttNoVerbatim = loaded.sttNoVerbatim
    }

    /// `nil` when the speed is not a number this can send — the caller gates Save on it rather
    /// than substituting a value, since a typo silently becoming 1.0 is the one outcome that
    /// looks like the setting not working.
    var speed: Double? {
        guard let value = Double(callSpeed), callSpeedRange.contains(value) else { return nil }
        return value
    }

    /// `.some(nil)` for an empty field (unset), `nil` for one that cannot be sent.
    var computerSpeedValue: Double?? {
        let trimmed = computerSpeed.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        guard let value = Double(trimmed), computerSpeedRange.contains(value) else { return nil }
        return .some(value)
    }

    var keyterms: [String] {
        sttKeyterms.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Why the key terms cannot be saved, or `nil` when they can.
    public var keytermProblem: String? {
        let terms = keyterms
        if terms.count > SttKeytermRules.maxCount { return "At most \(SttKeytermRules.maxCount) key terms" }
        return terms.lazy.compactMap(SttKeytermRules.problem(with:)).first
    }

    func asUpdate() -> SpokenVoiceSettingsUpdate? {
        guard let speed, let computerSpeed = computerSpeedValue, keytermProblem == nil else { return nil }
        let language = sttLanguage.trimmingCharacters(in: .whitespaces).lowercased()
        return SpokenVoiceSettingsUpdate(
            computerVoice: computerVoice.isEmpty ? nil : computerVoice,
            computerDelivery: computerDelivery.isEmpty ? nil : computerDelivery,
            computerSpeed: computerSpeed,
            callVoiceId: callVoiceId.isEmpty ? nil : callVoiceId,
            callSpeed: speed,
            sttKeyterms: keyterms,
            sttLanguage: language.isEmpty ? nil : language,
            sttNoVerbatim: sttNoVerbatim
        )
    }

    /// Locale-independent, because this string is parsed back with `Double(_:)`, which only ever
    /// accepts a dot. A comma decimal separator would round-trip into a save that cannot parse.
    private static func format(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

/// The synced voice settings — server-persisted, draft-and-save, the same shape
/// `SmtpSettingsStore` uses. One setting per thing, read by every transport: there is no
/// per-client override, because the backend is the only thing that speaks or transcribes.
@MainActor
@Observable
public final class SpokenVoiceSettingsStore {
    /// What the server holds. `nil` until `load()` completes, or after it fails — which is how a
    /// view tells "not loaded yet" from "loaded and clean".
    public private(set) var loaded: SpokenVoiceSettings?
    public var draft: SpokenVoiceSettingsDraft?

    public private(set) var isLoading = false
    public private(set) var isSaving = false
    public private(set) var loadError: String?
    public private(set) var saveError: String?

    private let apiClient: PaiApiClient

    public init(apiClient: PaiApiClient) {
        self.apiClient = apiClient
    }

    public var isDirty: Bool {
        guard let loaded, let draft else { return false }
        return draft != SpokenVoiceSettingsDraft(loaded: loaded)
    }

    public var isSpeedValid: Bool {
        draft?.speed != nil
    }

    public var isComputerSpeedValid: Bool {
        draft?.computerSpeedValue != nil
    }

    public var canSave: Bool {
        loaded != nil && isDirty && draft?.asUpdate() != nil && !isSaving
    }

    /// The debug-recordings toggle, saved on its own the moment it flips — it is not part of the
    /// voice groups' draft, and lives on the Debug Recordings sheet.
    public func setDebugRecordingsEnabled(_ enabled: Bool) async {
        saveError = nil
        do {
            let settings = try await apiClient.setDebugRecordingsEnabled(enabled)
            loaded = settings
            if draft == nil { draft = SpokenVoiceSettingsDraft(loaded: settings) }
        } catch {
            saveError = (error as? PaiError)?.userMessage ?? "\(error)"
        }
    }

    public func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let settings = try await apiClient.getVoiceSettings()
            loaded = settings
            draft = SpokenVoiceSettingsDraft(loaded: settings)
        } catch {
            loadError = (error as? PaiError)?.userMessage ?? "\(error)"
        }
    }

    public func save() async {
        guard canSave, let update = draft?.asUpdate() else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let settings = try await apiClient.updateVoiceSettings(update)
            loaded = settings
            draft = SpokenVoiceSettingsDraft(loaded: settings)
        } catch {
            saveError = (error as? PaiError)?.userMessage ?? "\(error)"
        }
    }
}
