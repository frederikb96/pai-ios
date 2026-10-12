import Foundation
import Observation

/// What `AlertRoutingStore` needs from the API; `PaiApiClient` conforms structurally.
public protocol AlertRoutingApiClient: Sendable {
    func getAlertRouting() async throws -> AlertRoutingSettings
    func updateAlertRouting(_ update: AlertRoutingUpdate) async throws -> AlertRoutingSettings
    func listSchedulerTasks(limit: Int?, offset: Int?) async throws -> SchedulerTaskListResponse
}

extension PaiApiClient: AlertRoutingApiClient {}

/// Alert routing: for each kind of alert, whether it goes to the person, to the agent task, or to
/// both. A backend setting, the same from every client, written as a whole map each time.
///
/// Port of `AlertRoutingSection.tsx`. The kinds come from the server; a kind not routed away from
/// `notify` is simply absent from `routes`.
@MainActor
@Observable
public final class AlertRoutingStore {
    public static let taskListLimit = 200

    /// `nil` until the first load succeeds.
    public private(set) var settings: AlertRoutingSettings?
    public private(set) var tasks: [ScheduledTask] = []
    public private(set) var isSaving = false
    public private(set) var errorMessage: String?

    private let api: any AlertRoutingApiClient

    public init(api: any AlertRoutingApiClient) {
        self.api = api
    }

    public func load() async {
        do {
            settings = try await api.getAlertRouting()
            errorMessage = nil
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "\(error)"
        }
    }

    /// The agent-task picker's choices, loaded only where the picker is. Without them the picker
    /// offers just the task already chosen; the routing itself still loads and saves.
    public func loadTasks() async {
        if let response = try? await api.listSchedulerTasks(limit: Self.taskListLimit, offset: nil) {
            tasks = response.tasks
        }
    }

    public func route(forKind kindId: String) -> AlertRoute {
        settings?.routes[kindId] ?? .notify
    }

    public func setRoute(_ route: AlertRoute, forKind kindId: String) async {
        guard let settings else { return }
        var routes = settings.routes
        // `notify` is the default and is not stored: an explicit entry would never clear.
        if route == .notify { routes.removeValue(forKey: kindId) } else { routes[kindId] = route }
        await save(AlertRoutingUpdate(routes: routes, agentTaskId: settings.agentTaskId))
    }

    public func setAgentTask(id: String?) async {
        guard let settings else { return }
        await save(AlertRoutingUpdate(routes: settings.routes, agentTaskId: id))
    }

    /// Whether the chosen task is among the loaded ones; when it is not, the picker still has to
    /// offer it by name.
    public var chosenTaskIsListed: Bool {
        guard let id = settings?.agentTaskId else { return true }
        return tasks.contains { $0.id == id }
    }

    /// Shown only when something is actually routed to the agent: the server then notifies
    /// instead, and says why in the alert itself.
    public var agentProblem: String? {
        guard let settings, settings.routes.values.contains(where: { $0 != .notify }) else { return nil }
        return settings.agentTaskProblem
    }

    /// One line for the settings row.
    public var summary: String? {
        guard let settings else { return nil }
        let routed = settings.routes.values.filter { $0 != .notify }.count
        switch routed {
        case 0: return "All to you"
        case 1: return "1 kind routed"
        default: return "\(routed) kinds routed"
        }
    }

    private func save(_ update: AlertRoutingUpdate) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            settings = try await api.updateAlertRouting(update)
            errorMessage = nil
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not save the alert routing"
        }
    }
}
