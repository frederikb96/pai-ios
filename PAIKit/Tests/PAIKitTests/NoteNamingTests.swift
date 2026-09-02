import XCTest

@testable import PAIKit

/// Picking a name for a note nobody has named. The backend refuses a duplicate outright, so
/// getting this wrong is not a cosmetic problem: the new-note button simply stops working, with an
/// error naming a note the reader may never have opened.
final class NoteNamingTests: XCTestCase {

    func testAFreeNameIsUsedAsItIs() {
        XCTAssertEqual(NoteNaming.freeName(base: "Untitled", taken: ["Groceries"]), "Untitled")
    }

    func testATakenNameGetsTheNextNumber() {
        XCTAssertEqual(NoteNaming.freeName(base: "Untitled", taken: ["Untitled"]), "Untitled 2")
    }

    /// The second new note of the day must not collide with the first one's replacement name.
    func testNumberingSkipsPastEveryNameAlreadyInUse() {
        XCTAssertEqual(
            NoteNaming.freeName(base: "Untitled", taken: ["Untitled", "Untitled 2", "Untitled 3"]),
            "Untitled 4")
    }

    /// A note's name is a filename in a synced folder, and a case-insensitive volume treats these
    /// as the same file — so a comparison that does not fold case produces a name the backend then
    /// rejects anyway.
    func testTheComparisonFoldsCase() {
        XCTAssertEqual(NoteNaming.freeName(base: "Untitled", taken: ["untitled"]), "Untitled 2")
    }

    func testAnEmptyBaseFallsBackToUntitled() {
        XCTAssertEqual(NoteNaming.freeName(base: "   ", taken: []), "Untitled")
    }

    // MARK: Local duplicate preview

    private func note(
        id: String, name: String, containerId: String? = "c1", pendingDelete: Bool = false
    ) -> NoteSummary {
        NoteSummary(
            id: id, name: name, summary: nil, containerId: containerId, favourite: false, tags: [],
            updatedAtMs: 0, pendingDelete: pendingDelete)
    }

    func testAnUnusedNameDoesNotCollide() {
        let notes = [note(id: "a", name: "Groceries")]
        XCTAssertFalse(NoteNaming.collides(name: "Recipes", containerId: "c1", excluding: "b", among: notes))
    }

    func testTypingBackTheNoteSOwnCurrentNameIsNotACollision() {
        let notes = [note(id: "a", name: "Groceries")]
        XCTAssertFalse(NoteNaming.collides(name: "Groceries", containerId: "c1", excluding: "a", among: notes))
    }

    func testAnotherNoteSNameIsACollision() {
        let notes = [note(id: "a", name: "Groceries")]
        XCTAssertTrue(NoteNaming.collides(name: "Groceries", containerId: "c1", excluding: "b", among: notes))
    }

    /// Case-insensitive only, matching the backend's own `name_key` (`lower(name)`) — a note
    /// name becomes a filename in a synced folder, and most filesystems fold case there.
    func testCollisionFoldsCase() {
        let notes = [note(id: "a", name: "Groceries")]
        XCTAssertTrue(NoteNaming.collides(name: "groceries", containerId: "c1", excluding: "b", among: notes))
    }

    /// Unlike `freeName` (a client-only naming nicety) and search's own
    /// `normalizeForNoteSearch`, the collision check does NOT fold diacritics — the backend's
    /// `name_key` doesn't either, and a real collision has to match what the server will
    /// actually reject.
    func testCollisionDoesNotFoldDiacritics() {
        let notes = [note(id: "a", name: "Müller")]
        XCTAssertFalse(NoteNaming.collides(name: "Muller", containerId: "c1", excluding: "b", among: notes))
    }

    /// v1 has no uniqueness on a note's name outside a container — a container-less note has no
    /// collision domain at all, never a match against every container's notes.
    func testAContainerLessNoteNeverCollides() {
        let notes = [note(id: "a", name: "Groceries", containerId: "c1")]
        XCTAssertFalse(NoteNaming.collides(name: "Groceries", containerId: nil, excluding: "b", among: notes))
    }

    /// A soft-deleted row is still in the index but is no longer using its name.
    func testAPendingDeleteRowIsNotACollision() {
        let notes = [note(id: "a", name: "Groceries", pendingDelete: true)]
        XCTAssertFalse(NoteNaming.collides(name: "Groceries", containerId: "c1", excluding: "b", among: notes))
    }

    /// Scoped to the container, matching `freeName`'s own scoping — the same name in a different
    /// synced folder is a different file on disk.
    func testANameTakenInAnotherContainerIsNotACollision() {
        let notes = [note(id: "a", name: "Groceries", containerId: "other")]
        XCTAssertFalse(NoteNaming.collides(name: "Groceries", containerId: "c1", excluding: "b", among: notes))
    }

    func testAnEmptyNameNeverCollides() {
        let notes = [note(id: "a", name: "Groceries")]
        XCTAssertFalse(NoteNaming.collides(name: "  ", containerId: "c1", excluding: "b", among: notes))
    }
}
