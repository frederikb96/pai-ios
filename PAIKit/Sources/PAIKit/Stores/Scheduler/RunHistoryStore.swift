import Foundation
import Observation

public protocol RunHistoryApiClient: Sendable {
    func listSchedulerTaskRuns(taskId: String, limit: Int?, offset: Int?) async throws -> SchedulerTaskRunsResponse
}

extension PaiApiClient: RunHistoryApiClient {}

/// A task's fire history, newest first — paged the same shape `RunHistory.tsx` pages a flat,
/// uniform-height list in. A full page's worth of rows coming back is what "there might be more"
/// means here; there is no separate total count to compare against.
@MainActor
@Observable
public final class RunHistoryStore {
    public static let pageSize = 30

    public private(set) var runs: [TaskRun] = []
    public private(set) var isLoading = false
    public private(set) var hasMore = true
    public private(set) var errorMessage: String?

    private let taskId: String
    private let api: RunHistoryApiClient
    private var offset = 0

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
            hasMore = page.runs.count == Self.pageSize
            errorMessage = nil
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load run history"
        }
    }
}
