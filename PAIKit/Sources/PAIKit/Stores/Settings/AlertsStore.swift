import Foundation
import Observation

/// What `AlertsStore` needs from the API; `PaiApiClient` conforms structurally.
public protocol AlertsApiClient: Sendable {
    func listAlerts() async throws -> AlertsResponse
    @discardableResult func clearAlerts(ids: [String]) async throws -> Int
}

extension PaiApiClient: AlertsApiClient {}

/// The open alerts shown in Settings. Acknowledging frees an alert's key — it is not a fix, and
/// the same fault raises a fresh alert — so a row leaves the list only once the backend confirms
/// the clear.
@MainActor
@Observable
public final class AlertsStore {
    /// `nil` until the first load succeeds, so a view can tell "not loaded" from "none open".
    public private(set) var alerts: [PaiAlert]?
    public private(set) var isClearing = false
    public private(set) var errorMessage: String?

    private let api: any AlertsApiClient

    public init(api: any AlertsApiClient) {
        self.api = api
    }

    public func load() async {
        do {
            alerts = try await api.listAlerts().alerts
            errorMessage = nil
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "\(error)"
        }
    }

    public func acknowledge(_ id: String) async {
        await clear([id])
    }

    /// Names every listed alert explicitly: the backend reads an absent `ids` as "clear all", so
    /// "all" here means the ids on screen, never an open-ended request.
    public func acknowledgeAll() async {
        await clear((alerts ?? []).map(\.id))
    }

    private func clear(_ ids: [String]) async {
        guard !ids.isEmpty, !isClearing else { return }
        isClearing = true
        defer { isClearing = false }
        do {
            try await api.clearAlerts(ids: ids)
            alerts = alerts?.filter { !ids.contains($0.id) }
            errorMessage = nil
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "\(error)"
        }
    }
}
