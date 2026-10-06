import XCTest
@testable import PAIKit

/// A tick in the rendered note writes to the body, so the one failure that matters is a tick
/// landing on a different line than the box that was tapped.
final class NoteTasksTests: XCTestCase {

    private func text(at mark: NoteTaskMark, in body: String) -> String {
        let bytes = Array(body.utf8)
        return String(decoding: bytes[(mark.offset - 1)...(mark.offset + 1)], as: UTF8.self)
    }

    private func trailing(of mark: NoteTaskMark, in body: String) -> String {
        let rest = Array(body.utf8)[(mark.offset + 2)...]
        return String(decoding: rest, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
    }

    private let body =
        "# Trip\n\n- [x] okok\n- [ ] ok\n  - [ ] nested\n\n> 1. [X] quoted\n\n- [X] last\n\n```\n- [ ] code, not a task\n```\n"

    /// Nested boxes are found, code is not, and each mark points between its brackets. A box in a
    /// block quote is not a task item to the parser here (it draws as literal text), so it is
    /// neither drawn as a box nor given a mark — and the boxes after it still point at their own lines.
    func testEachDrawnBoxPointsAtItsOwnBrackets() throws {
        let document = NotePreviewDocument(body: body, nameToId: [:])
        XCTAssertEqual(document.taskMarks.count, 4)
        XCTAssertEqual(document.taskMarks.map { text(at: $0, in: body) }, ["[x]", "[ ]", "[ ]", "[X]"])
        XCTAssertEqual(document.taskMarks.map(\.checked), [true, false, false, true])
        XCTAssertEqual(trailing(of: document.taskMarks[2], in: body), " nested")
        XCTAssertEqual(trailing(of: document.taskMarks[3], in: body), " last")
    }

    /// Offsets are bytes, so a multi-byte character earlier in the note must not shift them.
    func testOffsetsSurviveMultiByteTextAbove() throws {
        let note = "Zürich 🇨🇭 — Äpfel\n\n- [ ] one\n- [ ] two\n"
        let document = NotePreviewDocument(body: note, nameToId: [:])
        XCTAssertEqual(document.taskMarks.count, 2)
        let toggled = try XCTUnwrap(NoteTasks.toggled(note, mark: document.taskMarks[1]))
        XCTAssertEqual(toggled, "Zürich 🇨🇭 — Äpfel\n\n- [ ] one\n- [x] two\n")
    }

    /// A disagreement between the drawn page and the body's parse makes nothing tickable rather
    /// than something possibly wrong.
    func testNothingIsTickableWhenDrawnBoxesDisagreeWithTheBody() {
        let note = "- [ ] a\n- [x] b\n"
        XCTAssertEqual(NoteTasks.marks(in: note, drawn: [false, true]).count, 2)
        XCTAssertEqual(NoteTasks.marks(in: note, drawn: [false]), [])
        XCTAssertEqual(NoteTasks.marks(in: note, drawn: [false, false]), [])
    }

    func testToggleFlipsOnlyTheTappedBox() throws {
        let note = "- [ ] a\n- [ ] b\n- [x] c\n"
        let marks = NoteTasks.marks(in: note, drawn: [false, false, true])
        XCTAssertEqual(NoteTasks.toggled(note, mark: marks[0]), "- [x] a\n- [ ] b\n- [x] c\n")
        XCTAssertEqual(NoteTasks.toggled(note, mark: marks[2]), "- [ ] a\n- [ ] b\n- [ ] c\n")
    }

    /// The body changed since the page was drawn: the tap is dropped, not redirected.
    func testToggleIsRefusedWhenTheBodyMovedUnderTheTap() throws {
        let note = "- [ ] a\n- [ ] b\n"
        let mark = NoteTasks.marks(in: note, drawn: [false, false])[1]
        XCTAssertNil(NoteTasks.toggled("intro\n" + note, mark: mark), "text shifted")
        XCTAssertNil(NoteTasks.toggled("- [ ] a\n- [x] b\n", mark: mark), "box already in the other state")
        XCTAssertNil(NoteTasks.toggled("- [ ] a\n", mark: mark), "offset past the end")
    }

    /// The page's own walk and the document's ordinals agree: the box a row draws as Nth is the
    /// Nth mark, through nesting and across non-task items.
    func testOrdinalsFollowDrawingOrderThroughNesting() throws {
        let note = "- plain\n- [ ] a\n  - [x] inner\n- [ ] b\n\nbetween\n\n- [ ] later\n"
        let document = NotePreviewDocument(body: note, nameToId: [:])
        XCTAssertEqual(document.taskMarks.count, 4)
        XCTAssertEqual(document.items.map(\.firstTask), [0, 3, 3])

        guard case .block(.list(let list)) = document.items[0].kind else { return XCTFail("expected a list") }
        let itemStarts = NoteTasks.starts(of: list.items, from: document.items[0].firstTask)
        XCTAssertEqual(itemStarts, [0, 0, 2])
        let inner = NoteTasks.starts(of: list.items[1].blocks, from: itemStarts[1] + 1)
        // The paragraph holds no box; the nested list starts just past the item's own.
        XCTAssertEqual(inner, [1, 1])
        XCTAssertEqual(trailing(of: document.taskMarks[inner[1]], in: note), " inner")
        XCTAssertEqual(trailing(of: document.taskMarks[itemStarts[2]], in: note), " b")
        XCTAssertEqual(trailing(of: document.taskMarks[document.items[2].firstTask], in: note), " later")
    }

    func testANoteWithoutBoxesHasNoMarks() {
        XCTAssertEqual(NotePreviewDocument(body: "- a\n- b\n", nameToId: [:]).taskMarks, [])
    }
}
