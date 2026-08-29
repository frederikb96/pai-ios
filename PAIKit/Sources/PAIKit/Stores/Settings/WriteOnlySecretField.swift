import Foundation
import Observation

/// The shape the ElevenLabs API key and the SMTP password share: presence is readable, the
/// value never is. `GET /api/settings/secrets` answers "is one stored" for both in a single
/// call; a view shows `••••••••••` plus Replace/Clear when `status.set` is true, or a plain
/// input plus Save when it is false or `status` is `nil` (not yet known).
///
/// Built once and reused by both call sites (`SettingsStore.elevenLabsKey`,
/// `SmtpSettingsStore.password`) rather than duplicated — the two secrets differ only in
/// `SecretName` and in who applies the batched presence fetch to them.
@MainActor
@Observable
public final class WriteOnlySecretField {
    public let name: SecretName

    /// `nil` until the first presence fetch answers — a fresh launch and "confirmed unset" must
    /// read differently, since a voice gate greeting a cold start with "not configured" before
    /// it has even asked is exactly the failure this distinction exists to prevent.
    public private(set) var status: SecretStatus?
    public private(set) var isSaving = false
    public private(set) var errorMessage: String?

    private let apiClient: PaiApiClient

    public init(name: SecretName, apiClient: PaiApiClient) {
        self.name = name
        self.apiClient = apiClient
    }

    /// Applies a presence fetch performed elsewhere — `SecretStatusMap` covers both secrets in
    /// one call, so the caller fetches once and applies each half to the field it belongs to.
    public func applyStatus(_ status: SecretStatus?) {
        self.status = status
    }

    public func save(value: String) async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            status = try await apiClient.setSecret(name: name, value: value)
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "\(error)"
        }
    }

    public func clear() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            _ = try await apiClient.clearSecret(name: name)
            status = SecretStatus(set: false, updatedAt: nil)
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "\(error)"
        }
    }
}
