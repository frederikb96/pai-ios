import XCTest

@testable import PAIKit

/// Names for notes nobody has named, and the local preview of the backend's rename check.
final class NoteNamingTests: XCTestCase {

    // MARK: Today's date

    /// Fixed instants either side of the day boundary, both read in the user's own zone rather
    /// than UTC — the whole point of the function is getting this backwards for two hours a day.
    func testTodayNameUsesTheBerlinDateNotUTC() {
        // 2026-03-15T23:30:00Z is already 2026-03-16 00:30 in Berlin (CET, +1 in March).
        let lateUTC = Date(timeIntervalSince1970: 1_773_617_400)
        XCTAssertEqual(NoteNaming.todayName(now: lateUTC), "2026-03-16")
    }

    func testTodayNameIsZeroPadded() {
        let earlyMonthDay = Date(timeIntervalSince1970: 1_767_312_000)  // 2026-01-02T00:00:00Z
        XCTAssertEqual(NoteNaming.todayName(now: earlyMonthDay), "2026-01-02")
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
