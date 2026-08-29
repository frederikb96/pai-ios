import XCTest
@testable import PAIKit

@MainActor
final class SessionStoreDirectoryBrowserTests: XCTestCase {

    // MARK: - parentPath / childPath (pure, ported from a regex)

    func testParentPathDropsLastSegment() {
        XCTAssertEqual(DirectoryBrowserStore.parentPath(of: "/home/frederik/Programming"), "/home/frederik")
    }

    func testParentPathOfATopLevelDirectoryIsRoot() {
        XCTAssertEqual(DirectoryBrowserStore.parentPath(of: "/home"), "/")
    }

    func testParentPathOfRootStaysRoot() {
        XCTAssertEqual(DirectoryBrowserStore.parentPath(of: "/"), "/")
    }

    func testParentPathHandlesATrailingSlash() {
        XCTAssertEqual(DirectoryBrowserStore.parentPath(of: "/home/frederik/"), "/home")
    }

    func testChildPathJoinsWithoutDoublingASlash() {
        XCTAssertEqual(
            DirectoryBrowserStore.childPath(of: "/home/frederik", entering: "pai-cloud"), "/home/frederik/pai-cloud")
        XCTAssertEqual(
            DirectoryBrowserStore.childPath(of: "/home/frederik/", entering: "pai-cloud"), "/home/frederik/pai-cloud")
    }

    // MARK: - canGoUp

    func testCanGoUpIsTrueWhenNoRootsAreKnown() async {
        let api = FakeDirectoryBrowseApi()
        await api.setBrowseResult(.success(BrowseResult(path: "/home/frederik", directories: [], roots: [])))
        let store = DirectoryBrowserStore(agent: "vm", api: api)
        await store.start()

        // An agent too old to report roots means "no boundary known" — never "nothing allowed".
        XCTAssertTrue(store.canGoUp)
    }

    func testCanGoUpIsFalseExactlyAtAKnownRoot() async {
        let api = FakeDirectoryBrowseApi()
        await api.setBrowseResult(
            .success(BrowseResult(path: "/home/frederik", directories: [], roots: ["/home/frederik"])))
        let store = DirectoryBrowserStore(agent: "vm", api: api)
        await store.start()

        XCTAssertFalse(store.canGoUp)
    }

    func testCanGoUpIsTrueBelowAKnownRoot() async {
        let api = FakeDirectoryBrowseApi()
        await api.setBrowseResult(
            .success(BrowseResult(path: "/home/frederik/pai-cloud", directories: [], roots: ["/home/frederik"]))
        )
        let store = DirectoryBrowserStore(agent: "vm", api: api)
        await store.start()

        XCTAssertTrue(store.canGoUp)
    }

    // MARK: - filtering

    func testFilteredDirectoriesPreservesAlphabeticalOrder() async {
        let api = FakeDirectoryBrowseApi()
        await api.setBrowseResult(
            .success(
                BrowseResult(path: "/home/frederik", directories: ["zebra-cloud", "alpha-cloud", "middle"], roots: []))
        )
        let store = DirectoryBrowserStore(agent: "vm", api: api)
        await store.start()

        XCTAssertEqual(store.directories, ["alpha-cloud", "middle", "zebra-cloud"])
        store.filterText = "cloud"
        XCTAssertEqual(store.filteredDirectories, ["alpha-cloud", "zebra-cloud"])
    }

    func testNavigatingResetsTheFilter() async {
        let api = FakeDirectoryBrowseApi()
        await api.setBrowseResult(.success(BrowseResult(path: "/home/frederik", directories: ["pai-cloud"], roots: [])))
        let store = DirectoryBrowserStore(agent: "vm", api: api)
        await store.start()
        store.filterText = "something"

        await store.navigateInto("pai-cloud")

        XCTAssertEqual(store.filterText, "")
    }

    // MARK: - favorites: optimistic toggle + rollback

    func testTogglingAFavoriteIsOptimistic() async {
        let api = FakeDirectoryBrowseApi()
        await api.setBrowseResult(.success(BrowseResult(path: "/home/frederik", directories: [], roots: [])))
        let store = DirectoryBrowserStore(agent: "vm", api: api)
        await store.start()

        XCTAssertFalse(store.isFavorite("/home/frederik/pai-cloud"))
        await store.toggleFavorite("/home/frederik/pai-cloud")
        XCTAssertTrue(store.isFavorite("/home/frederik/pai-cloud"))

        await store.toggleFavorite("/home/frederik/pai-cloud")
        XCTAssertFalse(store.isFavorite("/home/frederik/pai-cloud"))
    }

    /// The star is the only feedback the tap gets — if the server call fails, the optimistic
    /// flip must be undone rather than left lying about what is actually saved.
    func testFailedAddFavoriteRollsBackTheOptimisticFlip() async {
        let api = FakeDirectoryBrowseApi()
        await api.setBrowseResult(.success(BrowseResult(path: "/home/frederik", directories: [], roots: [])))
        await api.setAddFavoriteResult(.failure(.transport("offline")))
        let store = DirectoryBrowserStore(agent: "vm", api: api)
        await store.start()

        await store.toggleFavorite("/home/frederik/pai-cloud")

        XCTAssertFalse(store.isFavorite("/home/frederik/pai-cloud"))
    }

    func testFailedRemoveFavoriteRollsBackTheOptimisticFlip() async {
        let api = FakeDirectoryBrowseApi()
        await api.setBrowseResult(.success(BrowseResult(path: "/home/frederik", directories: [], roots: [])))
        await api.setFavorites([FolderFavorite(path: "/home/frederik/pai-cloud", createdAt: nil)])
        await api.setRemoveFavoriteResult(.failure(.transport("offline")))
        let store = DirectoryBrowserStore(agent: "vm", api: api)
        await store.start()
        XCTAssertTrue(store.isFavorite("/home/frederik/pai-cloud"))

        await store.toggleFavorite("/home/frederik/pai-cloud")

        XCTAssertTrue(store.isFavorite("/home/frederik/pai-cloud"))
    }

    func testSortedFavoritesOrdersByFolderNameCaseInsensitively() async {
        let api = FakeDirectoryBrowseApi()
        await api.setBrowseResult(.success(BrowseResult(path: "/home/frederik", directories: [], roots: [])))
        await api.setFavorites([
            FolderFavorite(path: "/home/frederik/Zebra", createdAt: nil),
            FolderFavorite(path: "/home/frederik/alpha", createdAt: nil),
        ])
        let store = DirectoryBrowserStore(agent: "vm", api: api)
        await store.start()

        XCTAssertEqual(store.sortedFavorites.map(\.path), ["/home/frederik/alpha", "/home/frederik/Zebra"])
    }
}

extension FakeDirectoryBrowseApi {
    func setBrowseResult(_ result: Result<BrowseResult, PaiError>) {
        browseResult = result
    }

    func setFavorites(_ favorites: [FolderFavorite]) {
        self.favorites = favorites
    }

    func setAddFavoriteResult(_ result: Result<FolderFavorite, PaiError>) {
        addFavoriteResult = result
    }

    func setRemoveFavoriteResult(_ result: Result<PaiFavoriteRemovalResult, PaiError>) {
        removeFavoriteResult = result
    }
}
