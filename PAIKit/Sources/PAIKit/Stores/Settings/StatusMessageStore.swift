import Foundation
import Observation

/// What `StatusMessageStore` needs from the API; `PaiApiClient` conforms structurally.
public protocol StatusMessageApiClient: Sendable {
    func getStatusMessage() async throws -> StatusMessage
    func setStatusMessage(_ update: StatusMessageUpdate) async throws -> StatusMessage
    func clearStatusMessage() async throws -> StatusMessage
}

extension PaiApiClient: StatusMessageApiClient {}

/// The status message the backend appends to every scheduled-agent run: free text plus an
/// optional expiry, draft-and-save.
///
/// Whether the message is currently in effect is the server's answer (`StatusMessage.active`);
/// nothing here recomputes it from the expiry.
@MainActor
@Observable
public final class StatusMessageStore {
    /// `nil` until the first load succeeds.
    public private(set) var message: StatusMessage?
    public private(set) var draftText = ""
    public var hasExpiry = false
    public var draftExpiry = Date()
    public private(set) var isSaving = false
    public private(set) var errorMessage: String?

    private let api: any StatusMessageApiClient
    private let timeZone: TimeZone

    public init(api: any StatusMessageApiClient, timeZone: TimeZone = .current) {
        self.api = api
        self.timeZone = timeZone
    }

    /// Keeps the draft within the server's limit, which answers 422 above it.
    public func setDraftText(_ text: String) {
        draftText = String(text.prefix(StatusMessage.maxTextLength))
    }

    public func load() async {
        do {
            adopt(try await api.getStatusMessage())
            errorMessage = nil
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load the status message"
        }
    }

    /// An empty or whitespace-only draft clears the message on the server, so Save is offered for
    /// it only when there is something to clear.
    public var canSave: Bool {
        !isSaving && message != nil && isDirty
    }

    public var canClear: Bool {
        !isSaving && message?.text != nil
    }

    public var isDirty: Bool {
        guard let message else { return false }
        return draftText != (message.text ?? "")
            || hasExpiry != (message.expiresAt != nil)
            || (hasExpiry && expiryString(draftExpiry) != normalisedStoredExpiry(message))
    }

    public func save() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }
        let update = StatusMessageUpdate(text: draftText, expiresAt: hasExpiry ? expiryString(draftExpiry) : nil)
        do {
            adopt(try await api.setStatusMessage(update))
            errorMessage = nil
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not save the status message"
        }
    }

    public func clear() async {
        guard canClear else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            adopt(try await api.clearStatusMessage())
            errorMessage = nil
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not clear the status message"
        }
    }

    /// The expiry as the server holds it, for the line under the field.
    public var expiryDate: Date? {
        message?.expiresAt.flatMap(IsoTimestamp.date(from:))
    }

    private func adopt(_ message: StatusMessage) {
        self.message = message
        draftText = message.text ?? ""
        if let expiry = message.expiresAt.flatMap(IsoTimestamp.date(from:)) {
            hasExpiry = true
            draftExpiry = expiry
        } else {
            hasExpiry = false
        }
    }

    /// Whole seconds in the device's offset, the form a save sends.
    func expiryString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    /// The stored expiry run through the same formatting as a draft, so the comparison is between
    /// like strings rather than between the server's offset and the device's.
    private func normalisedStoredExpiry(_ message: StatusMessage) -> String? {
        message.expiresAt.flatMap(IsoTimestamp.date(from:)).map(expiryString)
    }
}
