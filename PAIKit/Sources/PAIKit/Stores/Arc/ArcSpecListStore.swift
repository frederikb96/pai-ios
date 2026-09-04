import Foundation
import Observation

/// The narrow slice of `PaiApiClient` this store needs — see `/subagents`' guidance on declaring
/// a protocol per consumer rather than mirroring the whole client.
public protocol ArcSpecListApiClient: Sendable {
    func listArcSpecs(query: String?, limit: Int, offset: Int) async throws -> [ArcSpec]
}

extension PaiApiClient: ArcSpecListApiClient {}

/// Every ARC spec, paged — the "Arc" entry under Apps. Styled after `SessionListStore`'s own
/// paging shape (a page size, an offset, a `hasMore` derived from whether the last page came
/// back full) but far smaller: there is no synced/server-filtered split and no semantic mode,
/// since `GET /api/arc/specs` is a single substring search over name and uuid with no separate
/// scoring endpoint to fall back to.
///
/// The caller debounces its own query text, the same division of labour `NotesBrowseStore`
/// documents on itself: SwiftUI's `.task(id:)` already cancels a superseded search, so a second
/// copy of that bookkeeping here could only drift from it.
@MainActor
@Observable
public final class ArcSpecListStore {
    public private(set) var specs: [ArcSpec] = []
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var hasMore = true
    public private(set) var errorMessage: String?

    private let api: ArcSpecListApiClient
    private var offset = 0
    private static let pageSize = 20

    public init(api: ArcSpecListApiClient) {
        self.api = api
    }

    /// Loads the first page for `query` (`nil` or blank asks for every spec). Replaces whatever
    /// was loaded before, matching a fresh search rather than appending to a stale one.
    public func loadInitial(query: String?) async {
        offset = 0
        hasMore = true
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await api.listArcSpecs(query: Self.normalized(query), limit: Self.pageSize, offset: 0)
            specs = page
            offset = page.count
            hasMore = page.count == Self.pageSize
        } catch {
            specs = []
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load specs"
        }
    }

    /// Appends the next page for the same `query` `loadInitial` was last called with. A no-op
    /// while a load is already in flight or the last page came back short of a full page (the
    /// same "short page means no more" signal `SessionListStore.loadMoreSyncedSessions` uses).
    public func loadMore(query: String?) async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await api.listArcSpecs(
                query: Self.normalized(query), limit: Self.pageSize, offset: offset)
            specs += page
            offset += page.count
            hasMore = page.count == Self.pageSize
        } catch {
            // Leaves whatever already loaded on screen rather than replacing it with an error —
            // matching `ArcSpecStore.refreshQuietly()`'s own reasoning: a background continuation
            // failing is not worth discarding content that is still showing correctly. The next
            // scroll-triggered call retries with the same offset, since `offset` only advances on
            // success.
        }
    }

    private static func normalized(_ query: String?) -> String? {
        guard let query else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
