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
    /// Waits for the request to have been MADE — not for its result to have been applied.
    ///
    /// 🚨 Those are different moments, and asserting on `store.rows` straight after this is a race
    /// the fast machine wins and CI loses. When the assertion is about what the response
    /// produced, wait for that instead: `awaitRows`.
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

    /// Poll until the store's rows match, or fail after a generous ceiling.
    private func awaitRows(
        _ store: SessionListStore, _ expected: [String], file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = ContinuousClock().now + .seconds(5)
        while ContinuousClock().now < deadline {
            if store.rows.map(\.id) == expected { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(store.rows.map(\.id), expected, file: file, line: line)
    }

    /// Assert the rows hold a value for a window rather than at one instant.
    private func assertRowsStay(
        _ store: SessionListStore, _ expected: [String], file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = ContinuousClock().now + .milliseconds(300)
        while ContinuousClock().now < deadline {
            guard store.rows.map(\.id) == expected else {
                XCTFail("rows became \(store.rows.map(\.id)) instead of staying \(expected)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
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
        // A debounce far longer than any wait below, so a search arriving at all can only mean it
        // bypassed the debounce. Sleeping a couple of milliseconds instead makes the test a claim
        // about how fast the machine schedules a task, which fails under a loaded suite.
        let store = makeStore(api: api, debounceNanos: 600_000_000_000)
        store.updateFilterText("release notes")

        store.commitFilterTextNow()

        let calls = await awaitSearchCalls(api, count: 1)
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
        // Same reasoning as the Enter key above: a debounce this long means a browse arriving at
        // all proves the chip did not go through it.
        let store = makeStore(api: api, debounceNanos: 600_000_000_000)

        store.setMachineFilter("laptop")

        let deadline = ContinuousClock().now + .seconds(5)
        while ContinuousClock().now < deadline {
            if await !api.getSessionsCalls.isEmpty { break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
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
        await awaitRows(store, ["hi"])
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
        await awaitRows(store, ["newest", "middle", "oldest"])
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
        await awaitRows(store, ["laptop-session"])

        // The stale request finally answers, and must be discarded rather than applied on top.
        // Held over a window rather than sampled once: a fixed sleep asserts how fast a loaded
        // machine resumes a continuation, and it fails for that reason rather than this one.
        await api.gate.release("browse:vm")
        await assertRowsStay(store, ["laptop-session"])
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
        await awaitRows(store, ["beta-session"])

        // Releasing the stale request is the actual subject: it answers last and must lose. A
        // fixed sleep here asserts that a loaded machine finishes a continuation within a few
        // milliseconds, which is a claim about the machine — and it failed once under a full
        // suite. Holding the assertion over a window instead can only fail if the stale result
        // genuinely wins, which is the thing being tested.
        await api.gate.release("search:alpha")
        await assertRowsStay(store, ["beta-session"])
    }

    /// Re-applying a filter (a fresh machine chip, replacing an already-loaded one) must not keep
    /// showing the previous filter's rows while its own fetch is in flight — a stale-but-nonempty
    /// `serverFilteredResults` defeats `isLoadingFirstResults`'s emptiness check, so the old rows
    /// sit there silently, looking like the new filter's answer.
    func testReapplyingAMachineFilterClearsStaleResultsWhileTheNewFetchIsInFlight() async {
        let api = FakeSessionListApi()
        await api.gate.arm("browse:laptop")
        await api.setGetSessionsResult { call in
            let id = call.agent == "vm" ? "vm-session" : "laptop-session"
            return .success(SessionsPage(sessions: [SessionFixture.make(id: id, agent: call.agent)], nextCursor: nil))
        }
        let store = makeStore(api: api)

        store.setMachineFilter("vm")
        await awaitRows(store, ["vm-session"])

        store.setMachineFilter("laptop")  // gated — does not resolve yet

        XCTAssertTrue(store.rows.isEmpty, "the previous filter's rows must not linger while the new fetch is in flight")
        XCTAssertEqual(store.emptyState, .loadingFirstResults)

        await api.gate.release("browse:laptop")
        await awaitRows(store, ["laptop-session"])
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
        // Wait for the browse to land rather than guessing how long it takes: the id filter below
        // is applied on top of whatever the server source holds, so filtering before it arrives
        // tests nothing and fails whenever the machine is busy.
        await awaitRows(store, ["abcd1234efgh", "zzzz9999wwww"])

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

        // Comfortably past any real wall-clock "now" the test runs at: `fetchIncremental`'s
        // cursor starts at `lastSessionSync`, which was stamped from the real clock by the
        // `loadInitialSessions()` call above, and a page must sort *after* that cursor to count
        // as forward progress.
        let fullPage = (0..<SessionListStore.sessionsPageSize).map {
            SessionFixture.make(id: "full-\($0)", updatedAt: "2099-01-01T00:00:0\($0 % 10)Z")
        }
        let partialPage = [SessionFixture.make(id: "tail", updatedAt: "2099-01-02T00:00:00Z")]
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

    /// A full page whose rows all share one `updated_at` leaves the cursor unable to advance —
    /// with no forward-progress guard, `fetchIncremental`'s `while true` never terminates and
    /// hammers the backend with the identical `since` forever. The fake fails outright past a
    /// handful of repeats, which turns a regression into an ordinary fast test failure instead of
    /// a hang.
    func testIncrementalPollStopsWhenAFullPageMakesNoCursorProgress() async {
        let api = FakeSessionListApi()
        await api.setGetSessionsResult { call in
            guard call.since == nil else { return .success(SessionsPage(sessions: [], nextCursor: nil)) }
            return .success(SessionsPage(sessions: [], nextCursor: nil))
        }
        let store = makeStore(api: api)
        await store.loadInitialSessions()

        let stuckPage = (0..<SessionListStore.sessionsPageSize).map {
            SessionFixture.make(id: "stuck-\($0)", updatedAt: "2099-01-01T00:00:00Z")
        }
        let callIndex = CallCounter()
        await api.setGetSessionsResult { call in
            guard call.since != nil else { return .success(SessionsPage(sessions: [], nextCursor: nil)) }
            defer { callIndex.value += 1 }
            guard callIndex.value < 5 else { return .failure(.transport("test: loop did not terminate")) }
            return .success(SessionsPage(sessions: stuckPage, nextCursor: nil))
        }

        await store.pollSyncedSessions()

        // The first call still advances the cursor from `lastSessionSync` (the real clock, well
        // before 2099) to the stuck page's shared timestamp — genuine progress. The second call
        // sends that same cursor back and gets the identical page again: no further progress, so
        // the loop must stop there rather than repeating it forever.
        let sinceCalls = (await api.getSessionsCalls).filter { $0.since != nil }
        XCTAssertEqual(
            sinceCalls.count, 2,
            "no further cursor progress must stop the loop instead of resending the identical `since` forever")
        XCTAssertEqual(store.syncedSessions.count, SessionListStore.sessionsPageSize, "the one stuck page still merges")
    }

    // MARK: - session(withId:)

    /// The case the report named directly: a session found only by search (source C) may be
    /// older than the pages already loaded into the synced list (source A) and so is absent from
    /// it — a lookup that only ever checks the synced list resolves to nothing for it.
    func testSessionWithIdFallsBackToServerFilteredResultsWhenAbsentFromTheSyncedList() async {
        let api = FakeSessionListApi()
        await api.setGetSessionsResult { call in
            guard call.since == nil else { return .success(SessionsPage(sessions: [], nextCursor: nil)) }
            return .success(SessionsPage(sessions: [SessionFixture.make(id: "synced-1")], nextCursor: nil))
        }
        await api.setSearchResult { _ in
            .success([SessionSearchResult(session: SessionFixture.make(id: "search-only"), score: nil)])
        }
        let store = makeStore(api: api)
        await store.loadInitialSessions()
        store.updateFilterText("old session")
        store.commitFilterTextNow()
        _ = await awaitSearchCalls(api, count: 1)
        // The call having been made is not the result having landed — wait for the thing the
        // assertions below are actually about.
        let deadline = ContinuousClock().now + .seconds(5)
        while ContinuousClock().now < deadline, store.session(withId: "search-only") == nil {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }

        XCTAssertEqual(store.session(withId: "synced-1")?.id, "synced-1")
        XCTAssertEqual(
            store.session(withId: "search-only")?.id, "search-only",
            "a search-only result must still resolve rather than falling back to nothing")
        XCTAssertNil(store.session(withId: "never-seen"))
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

    // MARK: - ensureSessionLoaded

    func testEnsureSessionLoadedIsANoOpWhenTheSessionIsAlreadyInTheSyncedList() async {
        let api = FakeSessionListApi()
        await api.setGetSessionsResult { _ in
            .success(SessionsPage(sessions: [SessionFixture.make(id: "s1")], nextCursor: nil))
        }
        let store = makeStore(api: api)
        await store.loadInitialSessions()

        await store.ensureSessionLoaded(id: "s1")

        let calls = await api.getSessionsCalls
        XCTAssertTrue(calls.allSatisfy { $0.q == nil }, "an already-loaded session must never trigger a q: fetch")
    }

    func testEnsureSessionLoadedFetchesByIdAndInsertsTheResult() async {
        let api = FakeSessionListApi()
        await api.setGetSessionsResult { call in
            guard call.q == "outside-window" else { return .success(SessionsPage(sessions: [], nextCursor: nil)) }
            return .success(SessionsPage(sessions: [SessionFixture.make(id: "outside-window")], nextCursor: nil))
        }
        let store = makeStore(api: api)

        await store.ensureSessionLoaded(id: "outside-window")

        XCTAssertEqual(store.session(withId: "outside-window")?.id, "outside-window")
    }

    /// Answered, and the answer was no: the id must be remembered so a later call does not
    /// re-fire the same request — the exact behaviour `session.ts`'s `ensureSessionLoaded` ports.
    func testEnsureSessionLoadedRemembersAnUnknownIdAndDoesNotAskAgain() async {
        let api = FakeSessionListApi()
        await api.setGetSessionsResult { _ in .success(SessionsPage(sessions: [], nextCursor: nil)) }
        let store = makeStore(api: api)

        await store.ensureSessionLoaded(id: "never-existed")
        XCTAssertTrue(store.unknownSessionIds.contains("never-existed"))

        await store.ensureSessionLoaded(id: "never-existed")

        let calls = (await api.getSessionsCalls).filter { $0.q == "never-existed" }
        XCTAssertEqual(calls.count, 1, "a second call for a known-missing id must not re-fetch")
    }

    /// A failed request is not an answer — the id must stay resolvable later rather than being
    /// remembered as missing.
    func testEnsureSessionLoadedLeavesTheIdRetryableAfterAFailedRequest() async {
        let api = FakeSessionListApi()
        await api.setGetSessionsResult { _ in .failure(.transport("offline")) }
        let store = makeStore(api: api)

        await store.ensureSessionLoaded(id: "flaky")

        XCTAssertFalse(store.unknownSessionIds.contains("flaky"))
    }

    // MARK: - applyLiveStatus

    func testApplyLiveStatusUpdatesTheMatchingRowInTheSyncedList() async {
        let api = FakeSessionListApi()
        await api.setGetSessionsResult { _ in
            .success(SessionsPage(sessions: [SessionFixture.make(id: "s1", state: .starting)], nextCursor: nil))
        }
        let store = makeStore(api: api)
        await store.loadInitialSessions()

        store.applyLiveStatus(
            sessionId: "s1", state: .ready, blocker: nil, working: true,
            activityCounts: ActivityCounts(agents: 2, tasks: 1)
        )

        XCTAssertEqual(store.syncedSessions.first?.state, .ready)
        XCTAssertEqual(store.syncedSessions.first?.working, true)
        XCTAssertEqual(store.syncedSessions.first?.activityCounts, ActivityCounts(agents: 2, tasks: 1))
    }

    func testApplyLiveStatusIsANoOpForASessionNotInAnyLoadedSource() async {
        let api = FakeSessionListApi()
        let store = makeStore(api: api)

        store.applyLiveStatus(sessionId: "not-loaded", state: .ready, blocker: nil, working: true, activityCounts: nil)

        XCTAssertTrue(store.syncedSessions.isEmpty)
    }

    // MARK: - deleteSession

    /// The row disappearing is the part that has to feel instant — this asserts it happens
    /// synchronously, before the real DELETE has any chance to have returned (the gate holds it
    /// open the whole test, so a row still present here would mean the removal was waiting on the
    /// network rather than happening up front).
    func testDeleteSessionRemovesTheRowAtOnce() async {
        let api = FakeSessionListApi()
        await api.setGetSessionsResult { _ in
            .success(SessionsPage(sessions: [SessionFixture.make(id: "s1")], nextCursor: nil))
        }
        await api.gate.arm("delete:s1")
        let store = makeStore(api: api)
        await store.loadInitialSessions()

        store.deleteSession(id: "s1")

        XCTAssertTrue(store.syncedSessions.isEmpty)
        await api.gate.release("delete:s1")
    }

    /// The counterpart to the immediate-removal assertion above: the real DELETE must actually go
    /// out, off the synchronous path, not merely be implied by the row's absence.
    func testDeleteSessionFiresTheRealDeleteWithoutWaiting() async {
        let api = FakeSessionListApi()
        await api.setGetSessionsResult { _ in
            .success(SessionsPage(sessions: [SessionFixture.make(id: "s1")], nextCursor: nil))
        }
        let store = makeStore(api: api)
        await store.loadInitialSessions()

        store.deleteSession(id: "s1")

        let deadline = ContinuousClock().now + .seconds(5)
        while await api.deleteSessionCalls.isEmpty, ContinuousClock().now < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let calls = await api.deleteSessionCalls
        XCTAssertEqual(calls, ["s1"])
    }

    /// A DELETE that never reaches the backend must not leave the list lying about what still
    /// exists there — the row comes back rather than staying silently gone.
    func testDeleteSessionRestoresTheRowIfTheRealDeleteFails() async {
        let api = FakeSessionListApi()
        await api.setGetSessionsResult { _ in
            .success(SessionsPage(sessions: [SessionFixture.make(id: "s1")], nextCursor: nil))
        }
        await api.setDeleteSessionResult(.failure(.transport("offline")))
        let store = makeStore(api: api)
        await store.loadInitialSessions()

        store.deleteSession(id: "s1")
        XCTAssertTrue(store.syncedSessions.isEmpty, "the row must vanish at once regardless of how the request ends")

        let deadline = ContinuousClock().now + .seconds(5)
        while store.syncedSessions.isEmpty, ContinuousClock().now < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(store.syncedSessions.map(\.id), ["s1"])
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

    func setDeleteSessionResult(_ result: Result<DeleteResponse, PaiError>) {
        deleteSessionResult = result
    }
}

/// A `var` captured by an escaping `@Sendable` closure and mutated afterwards is a data race the
/// compiler cannot rule out even where the test drives it single-threaded — a reference box makes
/// the sharing explicit instead of asserting it away (mirrors `PaiRequestFactoryTests`'s `TokenBox`).
private final class CallCounter: @unchecked Sendable {
    var value = 0
}
