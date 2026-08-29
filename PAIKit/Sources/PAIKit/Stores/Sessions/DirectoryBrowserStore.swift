import Foundation
import Observation

/// The narrow slice of `PaiApiClient` this store needs.
public protocol DirectoryBrowseApiClient: Sendable {
    func browse(path: String?, agent: String?) async throws -> BrowseResult
    func getFavorites() async throws -> [FolderFavorite]
    func addFavorite(path: String) async throws -> FolderFavorite
    func removeFavorite(path: String) async throws -> PaiFavoriteRemovalResult
}

extension PaiApiClient: DirectoryBrowseApiClient {}

/// Swift port of `pai-cloud/web/src/components/DirectoryBrowser.tsx`'s state — the modal the New
/// Session screen's "Custom" pill opens. `Select`ing commits `currentPath` (the directory the
/// browser is standing IN, not one that was merely tapped); the caller reads `currentPath` after
/// calling `select()` and decides what "committed" means (for the New Session screen, that is
/// `CreateSessionStore.selectWorkingDir(_:)`) — this store does not know about session creation.
///
/// Every browsable path is a `/home/frederik/...` path that exists on both machines and means a
/// different tree on each, so `agent` is fixed at `init` to whichever machine the caller is
/// launching on — there is no "browse a different machine" affordance inside one instance of
/// this store, matching the web (`directoryBrowserAgent` is set once, when the modal opens).
@MainActor
@Observable
public final class DirectoryBrowserStore {
    public let agent: String?

    public private(set) var currentPath: String = ""
    public private(set) var directories: [String] = []
    /// The folders this machine allows browsing. Empty from an agent too old to report them —
    /// read that as "no boundary known", never as "nothing allowed" (see `canGoUp`).
    public private(set) var roots: [String] = []
    public private(set) var favorites: [FolderFavorite] = []
    public private(set) var isLoading = false
    public private(set) var error: String?
    /// Narrows only the list already loaded for the current directory — never a recursive or
    /// nested search. Reset on every navigation, matching the web: a filter surviving a
    /// navigation into a different directory would silently hide everything there.
    public var filterText: String = ""

    private let api: DirectoryBrowseApiClient

    public init(agent: String?, api: DirectoryBrowseApiClient) {
        self.agent = agent
        self.api = api
    }

    // MARK: - The view's surface

    /// Alphabetical — the server already returns it that way, but the filter must preserve order
    /// rather than re-rank: a subsequence match on an already-sorted list stays sorted.
    public var filteredDirectories: [String] {
        directories.filter { SessionFilterMatch.fuzzyMatchesSubsequence(filterText, $0) }
    }

    /// Flat, alphabetical by folder name — the server returns it this way; an optimistic
    /// favorite add/remove above must keep that order without a round trip.
    public var sortedFavorites: [FolderFavorite] {
        favorites.sorted {
            SessionListFormat.basename($0.path).lowercased() < SessionListFormat.basename($1.path).lowercased()
        }
    }

    public var currentPathIsFavorite: Bool { favorites.contains { $0.path == currentPath } }

    public func isFavorite(_ path: String) -> Bool { favorites.contains { $0.path == path } }

    /// At an allowed root there is nothing above to show, so offering ".." would only ever
    /// produce a refusal. An agent reporting no roots is one too old to know its own boundary,
    /// and keeps the unrestricted behaviour — not the same as "nothing allowed".
    public var canGoUp: Bool { !(roots.count > 0 && roots.contains(currentPath)) }

    public func childPath(entering directory: String) -> String {
        Self.childPath(of: currentPath, entering: directory)
    }

    // MARK: - Actions

    /// Opens the browser at the agent's own default root and loads favorites — the same effect
    /// the web runs when the modal becomes visible. Call once per presentation.
    public func start() async {
        async let directory: Void = loadDirectory(path: nil)
        async let favoritesLoad: Void = loadFavorites()
        _ = await (directory, favoritesLoad)
    }

    public func navigateInto(_ directory: String) async {
        await loadDirectory(path: childPath(entering: directory))
    }

    public func navigateToFavorite(_ path: String) async {
        await loadDirectory(path: path)
    }

    public func navigateUp() async {
        guard canGoUp else { return }
        await loadDirectory(path: Self.parentPath(of: currentPath))
    }

    /// Optimistic — the star is the only feedback this click gets. Rolls back on failure so the
    /// star never lies for longer than the request takes.
    public func toggleFavorite(_ path: String) async {
        let wasFavorite = isFavorite(path)
        if wasFavorite {
            favorites.removeAll { $0.path == path }
        } else {
            favorites.append(FolderFavorite(path: path, createdAt: nil))
        }
        do {
            if wasFavorite {
                _ = try await api.removeFavorite(path: path)
            } else {
                _ = try await api.addFavorite(path: path)
            }
        } catch {
            if wasFavorite {
                favorites.append(FolderFavorite(path: path, createdAt: nil))
            } else {
                favorites.removeAll { $0.path == path }
            }
        }
    }

    // MARK: - Private

    private func loadDirectory(path: String?) async {
        isLoading = true
        error = nil
        filterText = ""
        do {
            let result = try await api.browse(path: path, agent: agent)
            currentPath = result.path
            directories = result.directories.sorted()
            roots = result.roots
        } catch {
            self.error = (error as? PaiError)?.userMessage ?? "Failed to browse directory"
        }
        isLoading = false
    }

    private func loadFavorites() async {
        // The star affordance just shows nothing favorited yet rather than blocking the browser
        // over a failed side request — favorites load independently of the current directory, so
        // a browse failure (agent hiccup, a bad path) must not take favorites down with it.
        favorites = (try? await api.getFavorites()) ?? favorites
    }

    static func childPath(of current: String, entering directory: String) -> String {
        current.hasSuffix("/") ? "\(current)\(directory)" : "\(current)/\(directory)"
    }

    /// Drops the last path segment (and any trailing slash) — port of
    /// `currentPath.replace(/\/[^/]+\/?$/, '') || '/'`. Every browsable path here is absolute.
    static func parentPath(of path: String) -> String {
        var trimmed = path
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let lastSlash = trimmed.lastIndex(of: "/") else { return "/" }
        let parent = String(trimmed[..<lastSlash])
        return parent.isEmpty ? "/" : parent
    }
}
