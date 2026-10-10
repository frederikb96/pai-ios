import Foundation
import Observation

public protocol SchedulerInsightsApiClient: Sendable {
    func getSchedulerInsights(days: Int) async throws -> SchedulerInsights
}

extension PaiApiClient: SchedulerInsightsApiClient {}

/// The scheduler's KPI page: last-week totals over finished scheduled runs and the tasks that
/// cost the most. The sums are the backend's; this only fetches and holds them.
@MainActor
@Observable
public final class SchedulerInsightsStore {
    public static let windowDays = 7

    public private(set) var insights: SchedulerInsights?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    private let api: SchedulerInsightsApiClient

    public init(api: SchedulerInsightsApiClient) {
        self.api = api
    }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            insights = try await api.getSchedulerInsights(days: Self.windowDays)
            errorMessage = nil
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load the insights"
        }
    }
}
