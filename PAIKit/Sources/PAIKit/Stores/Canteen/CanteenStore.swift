import Foundation
import Observation

public protocol CanteenApiClient: Sendable {
    func listCanteenEntries() async throws -> [CanteenEntry]
    func getCanteenAttachment(entryId: String, attachmentId: String) async throws -> Data
}

extension PaiApiClient: CanteenApiClient {}

/// The Canteen app's state: the forwarded canteen mails, newest first. Swift port of
/// `CanteenApp.tsx`.
@MainActor
@Observable
public final class CanteenStore {
    public private(set) var entries: [CanteenEntry] = []
    public private(set) var isLoading = true
    public private(set) var errorMessage: String?

    private let api: CanteenApiClient

    public init(api: CanteenApiClient) {
        self.api = api
    }

    public func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            entries = try await api.listCanteenEntries()
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load the canteen mails"
        }
    }

    /// The bytes of one PDF, or `nil` after setting `errorMessage` when it could not be fetched.
    public func loadAttachment(entryId: String, attachment: CanteenAttachment) async -> Data? {
        do {
            return try await api.getCanteenAttachment(entryId: entryId, attachmentId: attachment.id)
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not open the PDF"
            return nil
        }
    }
}
