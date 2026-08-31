import XCTest
@testable import PAIKit

/// `SubagentListStore` is kept live by watching the parent's own `activityCounts.agents` rather
/// than any stream of its own — see the store's doc comment for why. These tests exercise the
/// fold-in this depends on: a genuinely new subagent must prepend without disturbing an
/// already-loaded row's position, and an unrelated re-render of the same set must not look like
/// a prepend to a view deciding whether to compensate scroll.
@MainActor
final class SubagentListStoreTests: XCTestCase {
    private let parentId = "parent-1"

    private func makeSubagent(id: String, parentSessionId: String? = "parent-1", workingDir: String? = nil)
        -> Session
    {
        SessionFixture.make(id: id, workingDir: workingDir, kind: .subagent, parentSessionId: parentSessionId)
    }

    private func page(_ sessions: [Session], nextCursor: String? = nil) -> SessionsPage {
        SessionsPage(sessions: sessions, nextCursor: nextCursor)
    }

    func testLoadInitialFiltersOutRowsThatAreNotThisParentsOwnSubagents() async {
        let api = FakeSubagentListApi()
        let ownSubagent = makeSubagent(id: "a1")
        // Neither belongs on this screen: one is a plain conversation, the other a subagent of a
        // different parent. Both exercise the defensive client-side filter, since a
        // fixture-mode/misbehaving server can answer the same body regardless of the
        // `kind`/`parent` query it was actually asked.
        let notASubagent = SessionFixture.make(id: "c1", kind: .conversation)
        let someoneElsesSubagent = makeSubagent(id: "a2", parentSessionId: "someone-else")
        await api.setResults([.success(page([notASubagent, someoneElsesSubagent, ownSubagent]))])
        let store = SubagentListStore(parentSessionId: parentId, api: api)

        await store.loadInitial()

        XCTAssertEqual(store.subagents.map(\.id), ["a1"])
    }

    func testLoadMoreAppendsRatherThanReplacingTheFirstPage() async {
        let api = FakeSubagentListApi()
        let first = makeSubagent(id: "a1")
        let second = makeSubagent(id: "a2")
        await api.setResults([
            .success(page([first], nextCursor: "cursor-1")),
            .success(page([second], nextCursor: nil)),
        ])
        let store = SubagentListStore(parentSessionId: parentId, api: api)
        await store.loadInitial()
        XCTAssertTrue(store.hasMore)

        await store.loadMore()

        XCTAssertEqual(store.subagents.map(\.id), ["a1", "a2"])
        XCTAssertFalse(store.hasMore)
    }

    /// The very first observed count is a baseline, not a change — a screen that just finished
    /// its initial load must not immediately re-fetch on the first activity-count read.
    func testNoteParentAgentsCountFirstCallDoesNotRefetch() async {
        let api = FakeSubagentListApi()
        await api.setResults([.success(page([makeSubagent(id: "a1")]))])
        let store = SubagentListStore(parentSessionId: parentId, api: api)
        await store.loadInitial()
        let callsAfterLoad = await api.calls.count

        let prepended = await store.noteParentAgentsCount(1)

        XCTAssertFalse(prepended)
        let callsAfterFirstNote = await api.calls.count
        XCTAssertEqual(callsAfterFirstNote, callsAfterLoad)
    }

    /// A genuine count change that surfaces a brand-new id must prepend it while leaving the
    /// already-loaded row's position untouched — what a view relies on to know whether to
    /// compensate scroll at all.
    func testNoteParentAgentsCountChangeFoldsInANewRowAheadOfExisting() async {
        let api = FakeSubagentListApi()
        let existing = makeSubagent(id: "a1")
        await api.setResults([.success(page([existing]))])
        let store = SubagentListStore(parentSessionId: parentId, api: api)
        await store.loadInitial()
        await store.noteParentAgentsCount(1)

        let brandNew = makeSubagent(id: "a2")
        await api.setResults([.success(page([brandNew, existing]))])
        let prepended = await store.noteParentAgentsCount(2)

        XCTAssertTrue(prepended)
        XCTAssertEqual(store.subagents.map(\.id), ["a2", "a1"])
    }

    /// The exact sequence `SubagentListScreen` drives, not each half in isolation: its `.task`
    /// seeds the baseline with whatever the count already is right after `loadInitial()`, because
    /// `.onChange` never fires for the value already in place when the view first appears — only
    /// for a later change. Regression for the bug where that seed call was missing entirely: a
    /// session going from zero subagents to one showed nothing, because the FIRST real change was
    /// consumed as the baseline instead of triggering a refresh. The other tests above all pass an
    /// arbitrary baseline in by hand, which is why none of them caught it.
    func testSeedingAtLoadThenTheFirstRealChangeStillRefreshes() async {
        let api = FakeSubagentListApi()
        await api.setResults([.success(page([]))])
        let store = SubagentListStore(parentSessionId: parentId, api: api)
        await store.loadInitial()
        let callsAfterLoad = await api.calls.count

        // The screen's `.task` seeds with the count already in place — zero subagents running,
        // matching `loadInitial`'s own empty result — never an arbitrary constant. Checking the
        // call count, not just the return value, is what actually distinguishes "the guard
        // skipped this" from "the guard ran a fetch that happened to find nothing new": an empty
        // fixture would report `false` from a stray fetch too, and only the extra call reveals it.
        let seeded = await store.noteParentAgentsCount(0)
        XCTAssertFalse(seeded, "the seed call itself must never be read as a change")
        let callsAfterSeed = await api.calls.count
        XCTAssertEqual(callsAfterSeed, callsAfterLoad, "seeding the baseline must not itself trigger a fetch")

        let firstSubagent = makeSubagent(id: "a1")
        await api.setResults([.success(page([firstSubagent]))])
        let prepended = await store.noteParentAgentsCount(1)

        XCTAssertTrue(
            prepended, "the first real change after seeding must refresh, not be swallowed as a second baseline")
        XCTAssertEqual(store.subagents.map(\.id), ["a1"])
    }

    /// A count change whose refreshed page carries no id this store has not already seen updates
    /// rows in place and must answer `false` — the signal a view uses to skip its scroll
    /// compensation for an ordinary content update.
    func testNoteParentAgentsCountChangeWithNoNewIdsUpdatesInPlaceAndReportsNoPrepend() async {
        let api = FakeSubagentListApi()
        let original = makeSubagent(id: "a1", workingDir: "/original")
        await api.setResults([.success(page([original]))])
        let store = SubagentListStore(parentSessionId: parentId, api: api)
        await store.loadInitial()
        await store.noteParentAgentsCount(1)

        let updated = makeSubagent(id: "a1", workingDir: "/updated")
        await api.setResults([.success(page([updated]))])
        let prepended = await store.noteParentAgentsCount(2)

        XCTAssertFalse(prepended)
        XCTAssertEqual(store.subagents.map(\.id), ["a1"])
        XCTAssertEqual(store.subagents.first?.workingDir, "/updated")
    }
}

extension FakeSubagentListApi {
    func setResults(_ results: [Result<SessionsPage, PaiError>]) {
        self.results = results
    }
}
