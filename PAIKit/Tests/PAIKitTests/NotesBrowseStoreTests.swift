import Foundation
import XCTest

@testable import PAIKit

private final class FakeNotesBrowseApi: NotesBrowseApiClient, @unchecked Sendable {
    private(set) var searchCalls: [(q: String, limit: Int)] = []
    var searchResult: [NoteSemanticHit] = []
    var searchError: (any Error)?

    func searchNotesSemantic(q: String, limit: Int) async throws -> [NoteSemanticHit] {
        searchCalls.append((q: q, limit: limit))
        if let searchError { throw searchError }
        return searchResult
    }
}

@MainActor
final class NotesBrowseStoreTests: XCTestCase {

    func testSortOrderDefaultsToModifiedOnAFreshInstall() {
        let store = NotesBrowseStore(api: FakeNotesBrowseApi(), storage: SettingsInMemoryKeyValueStore())
        XCTAssertEqual(store.sortOrder, .modified)
    }

    /// The one thing this store persists — a fresh instance over the SAME storage must pick up
    /// what an earlier instance wrote, the way a relaunch would.
    func testSortOrderPersistsAcrossStoreInstances() {
        let storage = SettingsInMemoryKeyValueStore()
        let first = NotesBrowseStore(api: FakeNotesBrowseApi(), storage: storage)
        first.setSortOrder(.favouritesFirst)

        let second = NotesBrowseStore(api: FakeNotesBrowseApi(), storage: storage)
        XCTAssertEqual(second.sortOrder, .favouritesFirst)
    }

    func testSearchSemanticPassesTheQueryThrough() async throws {
        let api = FakeNotesBrowseApi()
        api.searchResult = [NoteSemanticHit(noteId: "n1", score: 0.9)]
        let store = NotesBrowseStore(api: api, storage: SettingsInMemoryKeyValueStore())

        let results = try await store.searchSemantic(q: "kubernetes migration")

        XCTAssertEqual(api.searchCalls.map(\.q), ["kubernetes migration"])
        XCTAssertEqual(results.map(\.noteId), ["n1"])
    }

    func testSearchSemanticPropagatesAnError() async {
        let api = FakeNotesBrowseApi()
        api.searchError = PaiError.transport("boom")
        let store = NotesBrowseStore(api: api, storage: SettingsInMemoryKeyValueStore())

        do {
            _ = try await store.searchSemantic(q: "x")
            XCTFail("expected the API's error to propagate")
        } catch {
            // Any error propagating is the point — the screen decides how to phrase it.
        }
    }
}
