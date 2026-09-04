import XCTest

@testable import PAIKit

/// One `actor` fake scripting `listArcSpecs`, recording every call so a test can assert on the
/// `offset`/`query` the store actually sent — not just on what it renders.
private actor FakeArcSpecListApi: ArcSpecListApiClient {
    struct Call: Equatable {
        let query: String?
        let limit: Int
        let offset: Int
    }

    private(set) var calls: [Call] = []
    var result: (@Sendable (Call) async -> Result<[ArcSpec], PaiError>)?

    func listArcSpecs(query: String?, limit: Int, offset: Int) async throws -> [ArcSpec] {
        let call = Call(query: query, limit: limit, offset: offset)
        calls.append(call)
        guard let result else { return [] }
        switch await result(call) {
        case .success(let specs): return specs
        case .failure(let error): throw error
        }
    }
}

private func makeSpec(_ uuid: String) -> ArcSpec {
    ArcSpec(
        uuid: uuid, name: "Spec \(uuid)", phase: "Build", effort: 2, projectId: nil, sessions: [],
        overview: nil, createdAt: "2026-09-01T00:00:00.000000+00:00",
        updatedAt: "2026-09-01T00:00:00.000000+00:00", rowCount: nil)
}

@MainActor
final class ArcSpecListStoreTests: XCTestCase {

    /// A full page (20 specs, the store's own page size) means there could be more — the same
    /// "did the last page come back full" signal `SessionListStore` uses, tested at the boundary
    /// rather than with a page far short of it.
    func testLoadInitialWithAFullPageLeavesHasMoreTrue() async {
        let api = FakeArcSpecListApi()
        let page = (0..<20).map { makeSpec("s\($0)") }
        await api.setResult { _ in .success(page) }
        let store = ArcSpecListStore(api: api)

        await store.loadInitial(query: nil)

        XCTAssertEqual(store.specs.count, 20)
        XCTAssertTrue(store.hasMore)
    }

    /// A short page — fewer than the page size — is the store's only signal that nothing is left
    /// to page in. Sized to 3, well short of 20, so the boundary can't be crossed by accident.
    func testLoadInitialWithAShortPageSetsHasMoreFalse() async {
        let api = FakeArcSpecListApi()
        let page = (0..<3).map { makeSpec("s\($0)") }
        await api.setResult { _ in .success(page) }
        let store = ArcSpecListStore(api: api)

        await store.loadInitial(query: nil)

        XCTAssertEqual(store.specs.count, 3)
        XCTAssertFalse(store.hasMore)
    }

    /// `loadMore` must ask for the NEXT page, not repeat the first — the offset the fake
    /// receives is what proves the store is actually paging rather than re-fetching page one
    /// under a different name.
    func testLoadMoreAsksForTheOffsetAfterWhatIsAlreadyLoaded() async {
        let api = FakeArcSpecListApi()
        let firstPage = (0..<20).map { makeSpec("first\($0)") }
        let secondPage = (0..<5).map { makeSpec("second\($0)") }
        await api.setResult { call in
            call.offset == 0 ? .success(firstPage) : .success(secondPage)
        }
        let store = ArcSpecListStore(api: api)
        await store.loadInitial(query: nil)

        await store.loadMore(query: nil)

        let calls = await api.calls
        XCTAssertEqual(calls.map(\.offset), [0, 20])
        XCTAssertEqual(store.specs.count, 25)
        XCTAssertFalse(store.hasMore)
    }

    /// The floor every scroll-triggered pager needs: once a short page has already said there is
    /// nothing left, a further call must not re-ask the server at all.
    func testLoadMoreIsANoOpOnceHasMoreIsFalse() async {
        let api = FakeArcSpecListApi()
        await api.setResult { _ in .success([makeSpec("only")]) }
        let store = ArcSpecListStore(api: api)
        await store.loadInitial(query: nil)
        XCTAssertFalse(store.hasMore)

        await store.loadMore(query: nil)

        let calls = await api.calls
        XCTAssertEqual(calls.count, 1, "loadMore must not call the server once hasMore is false")
    }

    /// A failed continuation keeps whatever is already on screen rather than clearing it — the
    /// same "a background failure must not discard good content" rule `ArcSpecStore.refreshQuietly`
    /// documents on itself. `offset` staying unadvanced is what lets the next attempt retry the
    /// same page instead of skipping it.
    func testLoadMoreFailureKeepsExistingSpecsAndLeavesOffsetUnadvanced() async {
        let api = FakeArcSpecListApi()
        let firstPage = (0..<20).map { makeSpec("first\($0)") }
        await api.setResult { call in
            call.offset == 0 ? .success(firstPage) : .failure(.transport("offline"))
        }
        let store = ArcSpecListStore(api: api)
        await store.loadInitial(query: nil)

        await store.loadMore(query: nil)

        XCTAssertEqual(store.specs.count, 20, "the failed page must not be appended or clear what loaded")
        XCTAssertTrue(store.hasMore, "a failure must not be read as the end of the list")

        // Retrying must ask for the SAME offset the failed call did — proof the offset was never
        // advanced on failure.
        await store.loadMore(query: nil)
        let calls = await api.calls
        XCTAssertEqual(calls.map(\.offset), [0, 20, 20])
    }

    /// A load that fails outright — never having shown anything — must surface an error rather
    /// than silently rendering an empty list, which reads identically to "no specs exist".
    func testLoadInitialFailureClearsSpecsAndSetsAnErrorMessage() async {
        let api = FakeArcSpecListApi()
        await api.setResult { _ in .failure(.transport("offline")) }
        let store = ArcSpecListStore(api: api)

        await store.loadInitial(query: nil)

        XCTAssertTrue(store.specs.isEmpty)
        XCTAssertNotNil(store.errorMessage)
    }

    /// Whitespace-only query text must reach the server as `nil`, the same "browse everything"
    /// request an empty search field means — never as a literal blank substring, which the
    /// backend would treat as a real (if useless) filter term.
    func testBlankQueryIsNormalizedToNilBeforeReachingTheApi() async {
        let api = FakeArcSpecListApi()
        await api.setResult { _ in .success([]) }
        let store = ArcSpecListStore(api: api)

        await store.loadInitial(query: "   ")

        let calls = await api.calls
        XCTAssertEqual(calls.first?.query, nil)
    }
}

extension FakeArcSpecListApi {
    fileprivate func setResult(_ result: @escaping @Sendable (Call) async -> Result<[ArcSpec], PaiError>) {
        self.result = result
    }
}
