import Foundation
import Observation

/// A text-field-friendly mirror of `VoiceSettings`'s writable fields.
///
/// Every field is a plain `String` — including the speed, so a half-typed number is a state the
/// input can be in rather than a save that silently rounds it. The empty-string/`nil` and
/// string/`Double` translations happen once, at the edges (`init(loaded:)`, `asUpdate()`),
/// rather than at every call site. Same shape as `SmtpSettingsDraft`.
public struct SpokenVoiceSettingsDraft: Sendable, Equatable {
    public var computerVoice: String
    public var computerDelivery: String
    public var callVoiceId: String
    public var callSpeed: String

    public init(loaded: SpokenVoiceSettings) {
        computerVoice = loaded.computerVoice ?? ""
        computerDelivery = loaded.computerDelivery ?? ""
        callVoiceId = loaded.callVoiceId ?? ""
        callSpeed = Self.format(loaded.callSpeed)
    }

    /// `nil` when the speed is not a number this can send — the caller gates Save on it rather
    /// than substituting a value, since a typo silently becoming 1.0 is the one outcome that
    /// looks like the setting not working.
    var speed: Double? {
        guard let value = Double(callSpeed), callSpeedRange.contains(value) else { return nil }
        return value
    }

    func asUpdate() -> SpokenVoiceSettingsUpdate? {
        guard let speed else { return nil }
        return SpokenVoiceSettingsUpdate(
            computerVoice: computerVoice.isEmpty ? nil : computerVoice,
            computerDelivery: computerDelivery.isEmpty ? nil : computerDelivery,
            callVoiceId: callVoiceId.isEmpty ? nil : callVoiceId,
            callSpeed: speed
        )
    }

    /// Locale-independent, because this string is parsed back with `Double(_:)`, which only ever
    /// accepts a dot. A comma decimal separator would round-trip into a save that cannot parse.
    private static func format(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

/// How the two spoken voices sound — server-persisted, draft-and-save, the same shape
/// `SmtpSettingsStore` uses. One setting per thing, read by every transport: there is no
/// per-client override, because the backend is the only thing that speaks.
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

    public var canSave: Bool {
        loaded != nil && isDirty && isSpeedValid && !isSaving
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
