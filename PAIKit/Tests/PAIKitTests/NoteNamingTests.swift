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
}
