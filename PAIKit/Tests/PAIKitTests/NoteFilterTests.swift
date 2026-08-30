import XCTest
@testable import PAIKit

private func makeNote(
    id: String = "1", name: String, summary: String? = nil, tags: [String] = []
) -> NoteSummary {
    NoteSummary(
        id: id, name: name, summary: summary, containerId: nil, favourite: false, tags: tags,
        updatedAtMs: 0, pendingDelete: false)
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
}
