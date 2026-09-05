import Foundation
import Observation

public protocol SchedulerListApiClient: Sendable {
    func listSchedulerTasks(limit: Int?, offset: Int?) async throws -> SchedulerTaskListResponse
}

extension PaiApiClient: SchedulerListApiClient {}

/// PAI's own scheduler task list. Swift port of `SchedulerApp.tsx`'s list half — a task pairs a
/// schedule with an optional gate script that decides whether to actually run; a scheduled
/// session is otherwise an ordinary session in every way, reachable through the session list's
/// own Scheduled filter, not through this app.
@MainActor
@Observable
public final class SchedulerListStore {
    public private(set) var tasks: [ScheduledTask] = []
    public private(set) var isLoading = true
    public private(set) var errorMessage: String?

    private let api: SchedulerListApiClient

    public init(api: SchedulerListApiClient) {
        self.api = api
    }

    public func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            tasks = try await api.listSchedulerTasks(limit: nil, offset: nil).tasks
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load scheduled tasks"
        }
    }
}
