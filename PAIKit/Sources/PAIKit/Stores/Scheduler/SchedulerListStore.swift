import Foundation
import Observation

public protocol SchedulerListApiClient: Sendable {
    func listSchedulerTasks(limit: Int?, offset: Int?) async throws -> SchedulerTaskListResponse
    func listInboxWakes() async throws -> InboxWakeListResponse
    func deleteInboxWake(id: String) async throws
}

extension PaiApiClient: SchedulerListApiClient {}

/// PAI's own scheduler task list, with the mailbox wake-ups beside it: together they are
/// everything that can start a session without a person. Swift port of `SchedulerApp.tsx`'s list half — a task pairs a
/// schedule with an optional gate script that decides whether to actually run; a scheduled
/// session is otherwise an ordinary session in every way, reachable through the session list's
/// own Scheduled filter, not through this app.
@MainActor
@Observable
public final class SchedulerListStore {
    public private(set) var tasks: [ScheduledTask] = []
    public private(set) var isLoading = true
    public private(set) var errorMessage: String?
    public private(set) var wakes: [InboxWake] = []
    /// Set when a wake-up could not be read or removed. The tasks stay usable either way.
    public private(set) var wakeErrorMessage: String?

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

    public func loadWakes() async {
        do {
            wakes = try await api.listInboxWakes().wakes
            wakeErrorMessage = nil
        } catch {
            wakeErrorMessage = (error as? PaiError)?.userMessage ?? "Could not load mailbox wake-ups"
        }
    }

    /// Removes the registration, then drops it from the list; a refused removal re-reads the
    /// list so what is shown is what the server holds.
    public func removeWake(id: String) async {
        do {
            try await api.deleteInboxWake(id: id)
            wakes.removeAll { $0.id == id }
            wakeErrorMessage = nil
        } catch {
            let message = (error as? PaiError)?.userMessage ?? "Could not remove the wake-up"
            await loadWakes()
            wakeErrorMessage = message
        }
    }
}
