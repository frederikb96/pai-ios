import XCTest
@testable import PAIKit

/// The session list's central complexity is routing between three sources and never showing a
/// stale or premature empty state while doing it — these tests target exactly that: the
/// debounce/immediate asymmetry, generation + real cancellation across a race, the threshold
/// filter never re-querying, and the subagent/id-query filtering `rows` applies on top of
/// whichever source is active.
@MainActor
final class SessionStoreListStoreTests: XCTestCase {

    // 20ms — fast enough for a suite, slow enough to reliably observe.
    private static let shortDebounceNanos: UInt64 = 20_000_000

    private func makeStore(
        api: FakeSessionListApi, debounceNanos: UInt64 = SessionStoreListStoreTests.shortDebounceNanos
    )
        -> SessionListStore
    {
        SessionListStore(api: api, debounceNanos: debounceNanos)
    }

    private func sleepPastDebounce() async {
        try? await Task.sleep(nanoseconds: Self.shortDebounceNanos * 3)
    }

    /// Wait until the fake has recorded `count` searches, or give up after a generous ceiling.
    ///
    /// Sleeping a fixed multiple of the debounce asserts that a loaded machine schedules a task
    /// within a fixed wall-clock window, which is a claim about the machine rather than about the
    /// debounce. Under a full suite it loses that race and reports a debounce failure that is not
    /// one. Waiting for the condition keeps the assertion honest and still fails when the search
    /// genuinely never fires.
    private func awaitSearchCalls(
        _ api: FakeSessionListApi, count: Int, file: StaticString = #filePath, line: UInt = #line
    ) async -> [FakeSessionListApi.SearchCall] {
        let deadline = ContinuousClock().now + .seconds(5)
        while ContinuousClock().now < deadline {
            let calls = await api.searchCalls
            if calls.count >= count { return calls }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let calls = await api.searchCalls
        XCTFail("expected \(count) search call(s), saw \(calls.count)", file: file, line: line)
        return calls
    }

    // MARK: - Filter routing: id fragment vs empty vs text

    func testIdFragmentNeverReachesTheServer() async {
        let api = FakeSessionListApi()
        let store = makeStore(api: api)

        store.updateFilterText("deadbeef1234")
        await sleepPastDebounce()

        let searchCalls = await api.searchCalls
        let getCalls = await api.getSessionsCalls
        XCTAssertTrue(searchCalls.isEmpty)
        XCTAssertTrue(getCalls.isEmpty)
        XCTAssertTrue(store.isIdQuery)
        XCTAssertFalse(store.isServerFiltered)
    }

    func testClearingTheFilterTextIsImmediateNotDebounced() async {
        let api = FakeSessionListApi()
        let store = makeStore(api: api)
        store.setMachineFilter("vm")  // makes the store server-filtered so clearing text is observable

        store.updateFilterText("")

        // No sleep at all — an immediate answer, unlike ordinary typing.
        XCTAssertFalse(store.isIdQuery)
        XCTAssertNil(store.searchError)
    }

    func testOrdinaryTypingIsDebouncedNotImmediate() async {
        let api = FakeSessionListApi()
        let store = makeStore(api: api)

        store.updateFilterText("release notes")

        let callsBeforeWaiting = await api.searchCalls
        XCTAssertTrue(callsBeforeWaiting.isEmpty, "a search must not fire before the debounce elapses")

        let callsAfterWaiting = await awaitSearchCalls(api, count: 1)
        XCTAssertEqual(callsAfterWaiting.map(\.q), ["release notes"])
    }

    /// Retyping quickly must cancel the pending debounce rather than firing once per keystroke —
    /// the whole reason the debounce exists.
    func testRetypingQuicklyCancelsThePendingDebounceAndFiresOnlyOnce() async {
        let api = FakeSessionListApi()
        let store = makeStore(api: api)

        store.updateFilterText("r")
        store.updateFilterText("re")
        store.updateFilterText("release")

        let calls = await awaitSearchCalls(api, count: 1)
        XCTAssertEqual(calls.map(\.q), ["release"])
    }

    /// The Enter key answers now rather than waiting out the debounce ordinary typing goes
    /// through — the asymmetry the report calls out by name.
    func testCommitFilterTextNowBypassesTheDebounce() async {
        let api = FakeSessionListApi()
        let store = makeStore(api: api)
        store.updateFilterText("release notes")

        store.commitFilterTextNow()

        // A short yield for the spawned fetch to actually reach the fake actor — far under the
        // debounce interval, so a call already present here proves this bypassed it rather than
        // merely landing lucky.
        try? await Task.sleep(nanoseconds: 2_000_000)
        let calls = await api.searchCalls
        XCTAssertEqual(calls.map(\.q), ["release notes"])
    }

    func testCommitFilterTextNowIsANoOpForAnIdQuery() async {
        let api = FakeSessionListApi()
        let store = makeStore(api: api)
        store.updateFilterText("deadbeef1234")

        store.commitFilterTextNow()

        let calls = await api.searchCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testMachineChipSelectionIsImmediate() async {
        let api = FakeSessionListApi()
        let store = makeStore(api: api)

        store.setMachineFilter("laptop")

        try? await Task.sleep(nanoseconds: 2_000_000)
        let calls = await api.getSessionsCalls
        XCTAssertEqual(calls.map(\.agent), ["laptop"])
    }

    func testThresholdChangeNeverRefetches() async {
        let api = FakeSessionListApi()
        await api.setSearchResult { _ in
            .success([
                SessionSearchResult(session: SessionFixture.make(id: "hi"), score: 0.9),
                SessionSearchResult(session: SessionFixture.make(id: "lo"), score: 0.1),
            ])
        }
        let store = makeStore(api: api)
        store.setSemanticMode(true)
        store.commitFilterTextNow()  // no-op (empty text), just establishing state
        store.updateFilterText("meaning search")
        let callsAfterSearch = await awaitSearchCalls(api, count: 1)
        XCTAssertEqual(callsAfterSearch.count, 1)

        store.setThreshold(0.5)
        store.setThreshold(0.8)

        let callsAfterThresholdChanges = await api.searchCalls
        XCTAssertEqual(callsAfterThresholdChanges.count, 1, "dragging the slider must never re-query")
        XCTAssertEqual(store.rows.map(\.id), ["hi"], "only the result at or above the threshold survives")
    }

    /// Filtering by threshold must never re-sort — the server already returns chronological
    /// order, and a re-sort here would silently start ranking by score instead.
    func testThresholdFilterPreservesServerOrder() async {
        let api = FakeSessionListApi()
        await api.setSearchResult { _ in
            .success([
                SessionSearchResult(
                    session: SessionFixture.make(id: "newest", lastActivityAt: "2026-03-03T00:00:00Z"), score: 0.4),
                SessionSearchResult(
                    session: SessionFixture.make(id: "middle", lastActivityAt: "2026-02-02T00:00:00Z"), score: 0.9),
                SessionSearchResult(
                    session: SessionFixture.make(id: "oldest", lastActivityAt: "2026-01-01T00:00:00Z"), score: 0.6),
            ])
        }
        let store = makeStore(api: api)
        store.setSemanticMode(true)
        store.updateFilterText("meaning search")
        _ = await awaitSearchCalls(api, count: 1)

        store.setThreshold(0.3)

        // Chronological (as the server sent it), not score-descending.
        XCTAssertEqual(store.rows.map(\.id), ["newest", "middle", "oldest"])
    }

    // MARK: - Races: generation + real cancellation

    /// The scenario the report names as the central failure mode: a slow request must never win
    /// over a faster, more recent one just because it happens to answer later.
    func testASlowerStaleRequestNeverOverwritesAFasterNewerOne() async {
        let api = FakeSessionListApi()
        await api.gate.arm("browse:vm")
        await api.gate.arm("browse:laptop")
        await api.setGetSessionsResult { call in
            let id = call.agent == "vm" ? "vm-session" : "laptop-session"
            return .success(SessionsPage(sessions: [SessionFixture.make(id: id, agent: call.agent)], nextCursor: nil))
        }
        let store = makeStore(api: api)

        store.setMachineFilter("vm")  // slow — gated, does not resolve yet
        store.setMachineFilter("laptop")  // fast — cancels the vm fetch's Task and starts a new one

        await api.gate.release("browse:laptop")
        await Task.yield()
        // Give the laptop fetch a moment to actually land before asserting.
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(store.rows.map(\.id), ["laptop-session"])

        // The vm request finally answers — its answer must be discarded, not applied on top.
        await api.gate.release("browse:vm")
        try? await Task.sleep(nanoseconds: 5_000_000)

        XCTAssertEqual(
            store.rows.map(\.id), ["laptop-session"], "the stale vm answer must not have overwritten the laptop rows")
    }

    /// Same race, through the search branch rather than the browse branch — the two fetch paths
    /// in `refetchServerFiltered` share the guard, but only a test that exercises both proves it.
    func testASlowerStaleSearchNeverOverwritesAFasterNewerOne() async {
        let api = FakeSessionListApi()
        await api.gate.arm("search:alpha")
        await api.gate.arm("search:beta")
        await api.setSearchResult { call in
            let id = call.q == "alpha" ? "alpha-session" : "beta-session"
            return .success([SessionSearchResult(session: SessionFixture.make(id: id), score: nil)])
        }
        let store = makeStore(api: api)

        store.updateFilterText("alpha")
        store.commitFilterTextNow()
        store.updateFilterText("beta")
        store.commitFilterTextNow()

        await api.gate.release("search:beta")
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(store.rows.map(\.id), ["beta-session"])

        await api.gate.release("search:alpha")
        try? await Task.sleep(nanoseconds: 5_000_000)

        XCTAssertEqual(store.rows.map(\.id), ["beta-session"])
    }

    // MARK: - rows: subagent filtering, id-query on top of a server-filtered source

    func testRowsExcludeSubagentsFromTheSyncedList() async {
        let api = FakeSessionListApi()
        await api.setGetSessionsResult { call in
            guard call.since == nil else { return .success(SessionsPage(sessions: [], nextCursor: nil)) }
            return .success(
                SessionsPage(
                    sessions: [
                        SessionFixture.make(id: "convo", kind: .conversation),
                        SessionFixture.make(id: "sub", kind: .subagent),
                    ], nextCursor: nil
                )
            )
        }
        let store = makeStore(api: api)
        await store.loadInitialSessions()

        XCTAssertEqual(store.rows.map(\.id), ["convo"])
    }

    /// An id query filters CLIENT-SIDE on top of whichever source is active — including a
    /// server-filtered (machine chip) source, which is the case most likely to be missed.
    func testIdQueryFiltersOnTopOfAServerFilteredSource() async {
        let api = FakeSessionListApi()
        await api.setGetSessionsResult { _ in
            .success(
                SessionsPage(
                    sessions: [
                        SessionFixture.make(id: "abcd1234efgh"),
                        SessionFixture.make(id: "zzzz9999wwww"),
                    ], nextCursor: nil
                )
            )
        }
        let store = makeStore(api: api)
        store.setMachineFilter("vm")
        try? await Task.sleep(nanoseconds: 5_000_000)

        store.updateFilterText("abcd1234")

        XCTAssertTrue(store.isServerFiltered, "the machine chip alone already makes this server-filtered")
        XCTAssertEqual(store.rows.map(\.id), ["abcd1234efgh"])
    }

    // MARK: - emptyState

    func testEmptyStateIsNoSessionsYetWhenTrulyEmptyAndUnfiltered() async {
        let api = FakeSessionListApi()
        await api.setGetSessionsResult { _ in .success(SessionsPage(sessions: [], nextCursor: nil)) }
        let store = makeStore(api: api)
        await store.loadInitialSessions()

        XCTAssertEqual(store.emptyState, .noSessionsYet)
    }

    func testEmptyStateIsNoMatchingSessionsAsSoonAsTextIsTypedEvenMidDebounce() async {
        let api = FakeSessionListApi()
        let store = makeStore(api: api)

        store.updateFilterText("nothing will match this")

        // Mid-debounce: no request has gone out yet, but the copy must already read as a real
        // (if premature) "no match" rather than the misleading "no sessions yet".
        XCTAssertEqual(store.emptyState, .noMatchingSessions)
    }

    func testEmptyStateIsLoadingFirstResultsWhileAMachineFetchHasNotAnsweredYet() async {
        let api = FakeSessionListApi()
        await api.gate.arm("browse:laptop")
        let store = makeStore(api: api)

        store.setMachineFilter("laptop")

        XCTAssertEqual(store.emptyState, .loadingFirstResults)

        await api.gate.release("browse:laptop")
    }

    // MARK: - hasMoreRows suppressed for an id query

    func testHasMoreRowsIsSuppressedForAnIdQueryEvenWhenTheUnderlyingSourceHasMore() async {
        let api = FakeSessionListApi()
        await api.setGetSessionsResult { call in
            guard call.since == nil, call.cursor == nil else {
                return .success(SessionsPage(sessions: [], nextCursor: nil))
            }
            return .success(SessionsPage(sessions: [SessionFixture.make(id: "abcd1234")], nextCursor: "more"))
        }
        let store = makeStore(api: api)
        await store.loadInitialSessions()
        XCTAssertTrue(store.hasMoreRows)

        store.updateFilterText("abcd1234")

        XCTAssertFalse(store.hasMoreRows)
    }

    // MARK: - Source A: incremental merge

    func testDeletedSessionIsRemovedFromTheSyncedListOnTheNextPoll() async {
        let api = FakeSessionListApi()
        await api.setGetSessionsResult { call in
            guard call.since == nil else { return .success(SessionsPage(sessions: [], nextCursor: nil)) }
            return .success(SessionsPage(sessions: [SessionFixture.make(id: "s1")], nextCursor: nil))
        }
        let store = makeStore(api: api)
        await store.loadInitialSessions()
        XCTAssertEqual(store.syncedSessions.map(\.id), ["s1"])

        await api.setGetSessionsResult { call in
            guard call.since != nil else { return .success(SessionsPage(sessions: [], nextCursor: nil)) }
            return .success(SessionsPage(sessions: [SessionFixture.make(id: "s1", status: .deleted)], nextCursor: nil))
        }
        await store.pollSyncedSessions()

        XCTAssertTrue(store.syncedSessions.isEmpty)
    }

    func testAnUpdatedSessionReplacesTheExistingRowOnTheNextPoll() async {
        let api = FakeSessionListApi()
        await api.setGetSessionsResult { call in
            guard call.since == nil else { return .success(SessionsPage(sessions: [], nextCursor: nil)) }
            return .success(SessionsPage(sessions: [SessionFixture.make(id: "s1", state: .starting)], nextCursor: nil))
        }
        let store = makeStore(api: api)
        await store.loadInitialSessions()

        await api.setGetSessionsResult { call in
            guard call.since != nil else { return .success(SessionsPage(sessions: [], nextCursor: nil)) }
            return .success(SessionsPage(sessions: [SessionFixture.make(id: "s1", state: .ready)], nextCursor: nil))
        }
        await store.pollSyncedSessions()

        XCTAssertEqual(store.syncedSessions.first?.state, .ready)
    }

    func testIncrementalPollPagesUntilAPartialPageThenAdvancesTheCursorToItsMax() async {
        let api = FakeSessionListApi()
        await api.setGetSessionsResult { call in
            guard call.since == nil else { return .success(SessionsPage(sessions: [], nextCursor: nil)) }
            return .success(SessionsPage(sessions: [], nextCursor: nil))
        }
        let store = makeStore(api: api)
        await store.loadInitialSessions()

        let fullPage = (0..<SessionListStore.sessionsPageSize).map {
            SessionFixture.make(id: "full-\($0)", updatedAt: "2026-01-01T00:00:0\($0 % 10)Z")
        }
        let partialPage = [SessionFixture.make(id: "tail", updatedAt: "2026-01-02T00:00:00Z")]
        let callIndex = CallCounter()
        await api.setGetSessionsResult { call in
            guard call.since != nil else { return .success(SessionsPage(sessions: [], nextCursor: nil)) }
            defer { callIndex.value += 1 }
            return .success(SessionsPage(sessions: callIndex.value == 0 ? fullPage : partialPage, nextCursor: nil))
        }

        await store.pollSyncedSessions()

        let sinceCalls = (await api.getSessionsCalls).filter { $0.since != nil }
        XCTAssertEqual(sinceCalls.count, 2, "a full page must trigger exactly one more page")
        XCTAssertTrue(store.syncedSessions.contains { $0.id == "tail" })
        XCTAssertEqual(store.syncedSessions.count, SessionListStore.sessionsPageSize + 1)
    }

    // MARK: - loadMoreSyncedSessions

    func testLoadMoreSyncedSessionsAppendsWithoutDuplicatingAnAlreadyLoadedRow() async {
        let api = FakeSessionListApi()
        await api.setGetSessionsResult { call in
            guard call.cursor == nil else { return .success(SessionsPage(sessions: [], nextCursor: nil)) }
            return .success(SessionsPage(sessions: [SessionFixture.make(id: "s1")], nextCursor: "cursor-1"))
        }
        let store = makeStore(api: api)
        await store.loadInitialSessions()
        XCTAssertTrue(store.hasMoreSyncedSessions)

        await api.setGetSessionsResult { call in
            guard call.cursor == "cursor-1" else { return .success(SessionsPage(sessions: [], nextCursor: nil)) }
            // A duplicate of `s1` mixed with a genuinely new row — the dedup must keep exactly one `s1`.
            return .success(
                SessionsPage(sessions: [SessionFixture.make(id: "s1"), SessionFixture.make(id: "s2")], nextCursor: nil))
        }
        await store.loadMoreSyncedSessions()

        XCTAssertEqual(store.syncedSessions.map(\.id), ["s1", "s2"])
        XCTAssertFalse(store.hasMoreSyncedSessions)
    }

    // MARK: - prependOptimisticSession

    func testPrependOptimisticSessionInsertsAtTheTop() async {
        let api = FakeSessionListApi()
        await api.setGetSessionsResult { _ in
            .success(SessionsPage(sessions: [SessionFixture.make(id: "existing")], nextCursor: nil))
        }
        let store = makeStore(api: api)
        await store.loadInitialSessions()

        store.prependOptimisticSession(SessionFixture.make(id: "brand-new"))

        XCTAssertEqual(store.syncedSessions.map(\.id), ["brand-new", "existing"])
    }
}

extension FakeSessionListApi {
    func setGetSessionsResult(_ closure: @escaping @Sendable (GetSessionsCall) async -> Result<SessionsPage, PaiError>)
    {
        getSessionsResult = closure
    }

    func setSearchResult(_ closure: @escaping @Sendable (SearchCall) async -> Result<[SessionSearchResult], PaiError>) {
        searchResult = closure
    }
}

/// A `var` captured by an escaping `@Sendable` closure and mutated afterwards is a data race the
/// compiler cannot rule out even where the test drives it single-threaded — a reference box makes
/// the sharing explicit instead of asserting it away (mirrors `PaiRequestFactoryTests`'s `TokenBox`).
private final class CallCounter: @unchecked Sendable {
    var value = 0
}
