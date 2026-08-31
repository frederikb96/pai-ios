import XCTest
@testable import PAIKit

private func makeNote(
    id: String = "1", name: String, summary: String? = nil, tags: [String] = [],
    favourite: Bool = false, updatedAtMs: Int = 0
) -> NoteSummary {
    NoteSummary(
        id: id, name: name, summary: summary, containerId: nil, favourite: favourite, tags: tags,
        updatedAtMs: updatedAtMs, pendingDelete: false)
}

final class NoteFilterTests: XCTestCase {

    // MARK: - noteMatchesQuery

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(noteMatchesQuery(makeNote(name: "Anything"), query: ""))
    }

    func testMatchesSubstringOfName() {
        XCTAssertTrue(noteMatchesQuery(makeNote(name: "Kubernetes Migration"), query: "migrat"))
    }

    func testMatchesSubstringOfSummaryWhenNameDoesNotMatch() {
        XCTAssertTrue(noteMatchesQuery(makeNote(name: "Untitled", summary: "notes about kubernetes"), query: "kube"))
    }

    func testNoMatchWhenNeitherFieldContainsQuery() {
        XCTAssertFalse(noteMatchesQuery(makeNote(name: "Grocery List", summary: "milk, eggs"), query: "kubernetes"))
    }

    /// A phone keyboard makes typing an umlaut inconvenient — "muller" must find "Müller".
    func testMatchIsDiacriticInsensitive() {
        XCTAssertTrue(noteMatchesQuery(makeNote(name: "Müller Contract"), query: "muller"))
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertTrue(noteMatchesQuery(makeNote(name: "Kubernetes"), query: "KUBE"))
    }

    // MARK: - collectTags

    /// `#SVA` and `#sva` are one tag in Obsidian, folded here the same way — but the label shown
    /// keeps the FIRST spelling encountered rather than flattening to lower case.
    func testTagsAreCaseFoldedButKeepFirstSpelling() {
        let notes = [makeNote(name: "a", tags: ["SVA"]), makeNote(name: "b", tags: ["sva"])]
        let tags = collectTags(notes)
        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(tags[0].label, "SVA")
        XCTAssertEqual(tags[0].count, 2)
    }

    func testTagsAreSortedByCountDescendingThenKeyAscending() {
        let notes = [
            makeNote(name: "a", tags: ["rare"]),
            makeNote(name: "b", tags: ["common"]),
            makeNote(name: "c", tags: ["common"]),
        ]
        let tags = collectTags(notes)
        XCTAssertEqual(tags.map(\.key), ["common", "rare"])
    }

    // MARK: - noteHasAllTags

    func testEmptySelectionMatchesEveryNote() {
        XCTAssertTrue(noteHasAllTags(makeNote(name: "a", tags: []), selected: []))
    }

    /// Freddy was explicit that multiple selected tags narrow by AND, never OR.
    func testSelectionRequiresEveryTagPresent() {
        let note = makeNote(name: "a", tags: ["work", "urgent"])
        XCTAssertTrue(noteHasAllTags(note, selected: ["work", "urgent"]))
        XCTAssertFalse(noteHasAllTags(note, selected: ["work", "personal"]))
    }

    func testTagSelectionIsCaseInsensitive() {
        let note = makeNote(name: "a", tags: ["SVA"])
        XCTAssertTrue(noteHasAllTags(note, selected: ["sva"]))
    }

    // MARK: - sortNotes

    func testModifiedOrdersMostRecentlyUpdatedFirst() {
        let notes = [
            makeNote(id: "old", name: "b", updatedAtMs: 100),
            makeNote(id: "new", name: "a", updatedAtMs: 200),
        ]
        XCTAssertEqual(sortNotes(notes, order: .modified).map(\.id), ["new", "old"])
    }

    func testNameOrdersAlphabeticallyFoldingCase() {
        let notes = [
            makeNote(id: "b", name: "banana"),
            makeNote(id: "a", name: "Apple"),
        ]
        XCTAssertEqual(sortNotes(notes, order: .name).map(\.id), ["a", "b"])
    }

    /// Two notes sharing a name still need a deterministic order — most recently modified wins,
    /// the same tie-break every other case in this function uses.
    func testNameTiesBreakOnMostRecentlyModified() {
        let notes = [
            makeNote(id: "old", name: "Same", updatedAtMs: 100),
            makeNote(id: "new", name: "Same", updatedAtMs: 200),
        ]
        XCTAssertEqual(sortNotes(notes, order: .name).map(\.id), ["new", "old"])
    }

    /// The whole point of this order: a favourite outranks recency, not the other way round.
    func testFavouritesFirstOutranksModifiedTime() {
        let notes = [
            makeNote(id: "recent", name: "a", favourite: false, updatedAtMs: 500),
            makeNote(id: "old-favourite", name: "b", favourite: true, updatedAtMs: 1),
        ]
        XCTAssertEqual(sortNotes(notes, order: .favouritesFirst).map(\.id), ["old-favourite", "recent"])
    }

    func testFavouritesFirstTiesBreakOnMostRecentlyModified() {
        let notes = [
            makeNote(id: "old", name: "a", favourite: true, updatedAtMs: 100),
            makeNote(id: "new", name: "b", favourite: true, updatedAtMs: 200),
        ]
        XCTAssertEqual(sortNotes(notes, order: .favouritesFirst).map(\.id), ["new", "old"])
    }
}
