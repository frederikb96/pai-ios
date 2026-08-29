import Foundation
import Observation

/// A plain, text-field-friendly mirror of `SmtpSettings`'s writable fields — port of
/// `SettingsPanel.tsx`'s Alert Mail draft. `SmtpSettings.host`/`username`/`fromAddress` are
/// `String?` on the wire (empty means "not set"); the draft keeps them as plain `String` so a
/// view can bind a text field directly, and the empty-string/`nil` translation happens once, at
/// the edges (`init(loaded:)`, `asUpdate()`), rather than at every call site.
public struct SmtpSettingsDraft: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var security: SmtpSecurity
    public var username: String
    public var fromAddress: String
    public var recipient: String
    public var enabled: Bool

    public init(loaded: SmtpSettings) {
        host = loaded.host ?? ""
        port = loaded.port
        security = loaded.security
        username = loaded.username ?? ""
        fromAddress = loaded.fromAddress ?? ""
        recipient = loaded.recipient
        enabled = loaded.enabled
    }

    /// The Save button PUTs every field, not a selective patch — see `SmtpSettingsUpdate`'s doc
    /// comment for why a partial patch cannot express "clear to null" and this project follows
    /// the web's whole-draft pattern instead of building one.
    func asUpdate() -> SmtpSettingsUpdate {
        SmtpSettingsUpdate(
            host: host.isEmpty ? nil : host,
            port: port,
            security: security,
            username: username.isEmpty ? nil : username,
            fromAddress: fromAddress.isEmpty ? nil : fromAddress,
            recipient: recipient,
            enabled: enabled
        )
    }
}

/// The Alert Mail (SMTP) section — server-persisted, draft-and-save, plus the shared
/// write-only password field. Port of `SettingsPanel.tsx`'s SMTP block and
/// `stores/settings.ts`'s absence of one: the web has no dedicated SMTP store, holding the
/// draft as component state instead, but nothing here can be component state, so this exists as
/// its own store.
@MainActor
@Observable
public final class SmtpSettingsStore {
    public enum TestOutcome: Equatable {
        case sent
        case failed(String)
    }

    /// What the server holds. `nil` until `load()` completes, or after it fails — every
    /// draft/dirty/save operation is meaningless before then, and `nil` is how a view tells "not
    /// loaded yet" from "loaded and clean".
    public private(set) var loaded: SmtpSettings?
    public var draft: SmtpSettingsDraft?

    public let password: WriteOnlySecretField

    public private(set) var isLoading = false
    public private(set) var isSaving = false
    public private(set) var isSendingTest = false
    public private(set) var loadError: String?
    public private(set) var saveError: String?
    public private(set) var testOutcome: TestOutcome?

    private let apiClient: PaiApiClient

    public init(apiClient: PaiApiClient) {
        self.apiClient = apiClient
        self.password = WriteOnlySecretField(name: .smtpPassword, apiClient: apiClient)
    }

    /// The draft differs from what the server holds. Drives Save's enabled state and gates
    /// "Send test mail", which must use what is stored, not an unsaved draft.
    public var isDirty: Bool {
        guard let loaded, let draft else { return false }
        return draft != SmtpSettingsDraft(loaded: loaded)
    }

    public var isPortValid: Bool {
        guard let draft else { return false }
        return (1...65_535).contains(draft.port)
    }

    public var isRecipientValid: Bool {
        guard let draft else { return false }
        return draft.recipient.contains("@")
    }

    public var canSave: Bool {
        loaded != nil && isDirty && isPortValid && isRecipientValid && !isSaving
    }

    public var canSendTest: Bool {
        loaded != nil && !isDirty && !isSendingTest
    }

    public func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let settings = try await apiClient.getSmtpSettings()
            loaded = settings
            draft = SmtpSettingsDraft(loaded: settings)
        } catch {
            loadError = (error as? PaiError)?.userMessage ?? "\(error)"
        }
    }

    public func save() async {
        guard let draft, canSave else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let settings = try await apiClient.updateSmtpSettings(draft.asUpdate())
            loaded = settings
            self.draft = SmtpSettingsDraft(loaded: settings)
        } catch {
            saveError = (error as? PaiError)?.userMessage ?? "\(error)"
        }
    }

    public func sendTest() async {
        guard canSendTest else { return }
        isSendingTest = true
        testOutcome = nil
        defer { isSendingTest = false }
        do {
            _ = try await apiClient.testSmtpSettings()
            testOutcome = .sent
        } catch {
            testOutcome = .failed((error as? PaiError)?.userMessage ?? "\(error)")
        }
    }
}
