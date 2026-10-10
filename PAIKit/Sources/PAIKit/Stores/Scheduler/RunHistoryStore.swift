import Foundation
import Observation

public protocol RunHistoryApiClient: Sendable {
    func listSchedulerTaskRuns(taskId: String, limit: Int?, offset: Int?) async throws -> SchedulerTaskRunsResponse
}

extension PaiApiClient: RunHistoryApiClient {}

/// A task's fire history, newest first — paged the same shape `RunHistory.tsx` pages a flat
/// list in. The history is never pruned, so it can be arbitrarily long; the list view realizes
/// only the rows near the viewport, and the next page is requested a few rows before the end.
/// "There might be more" is a full page back with fewer loaded than the server's `total`.
@MainActor
@Observable
public final class RunHistoryStore {
    public static let pageSize = 100
    /// How many rows from the end of what is loaded a row appearing starts the next page.
    public static let loadAheadRows = 10

    public private(set) var runs: [TaskRun] = []
    public private(set) var isLoading = false
    public private(set) var hasMore = true
    public private(set) var total: Int?
    public private(set) var errorMessage: String?

    private let taskId: String
    private let api: RunHistoryApiClient
    private var offset = 0

    /// Whether a row appearing on screen should start the next page: it is within the last
    /// `loadAheadRows` of what is loaded.
    public func shouldLoadMore(onAppearing run: TaskRun) -> Bool {
        guard hasMore, let index = runs.lastIndex(where: { $0.id == run.id }) else { return false }
        return index >= runs.count - Self.loadAheadRows
    }

    public init(taskId: String, api: RunHistoryApiClient) {
        self.taskId = taskId
        self.api = api
    }

    public func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await api.listSchedulerTaskRuns(taskId: taskId, limit: Self.pageSize, offset: offset)
            runs.append(contentsOf: page.runs)
            offset += page.runs.count
            total = page.total
            hasMore = page.runs.count == Self.pageSize && offset < (page.total ?? Int.max)
            errorMessage = nil
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load run history"
        }
    }
}
