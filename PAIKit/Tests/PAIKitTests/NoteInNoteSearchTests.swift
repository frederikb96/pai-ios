import XCTest
@testable import PAIKit

final class NoteInNoteSearchTests: XCTestCase {

    func testEmptyQueryFindsNothing() {
        XCTAssertTrue(findOccurrences(body: "some text", query: "").isEmpty)
    }

    func testFindsEveryNonOverlappingOccurrence() {
        let occurrences = findOccurrences(body: "cat cat cat", query: "cat")
        XCTAssertEqual(occurrences.map(\.offset), [0, 4, 8])
    }

    func testMatchIsCaseInsensitive() {
        let occurrences = findOccurrences(body: "Kubernetes cluster", query: "KUBE")
        XCTAssertEqual(occurrences.count, 1)
    }

    /// `offset`/`length` index into `body`, not into `context` — a caller highlighting the hit
    /// must be able to slice the body it searched directly with them, regardless of how far into
    /// the body the match sits (`context` only ever covers a fixed-size window around it).
    func testMatchOffsetAndLengthAreAbsoluteIntoBody() {
        let body = String(repeating: "x", count: 80) + "needle" + String(repeating: "y", count: 80)
        let occurrences = findOccurrences(body: body, query: "needle")
        let occ = occurrences[0]
        let chars = Array(body)
        XCTAssertEqual(String(chars[occ.offset..<(occ.offset + occ.length)]), "needle")
    }

    /// Composes `findOccurrences` with `highlightRanges` the way `NotePreviewBlockView` actually
    /// uses them — the shape neither piece tested in isolation would catch. Regression for the
    /// bug where a match anywhere but the very start of the text was highlighted at an unrelated
    /// position, because a context-relative offset was reused directly as one into the block.
    func testHighlightRangesLandOnEveryRealMatchNotJustTheFirst() {
        let text = String(repeating: "x", count: 80) + "Test" + String(repeating: "y", count: 20) + "Test end"
        let ranges = highlightRanges(in: text, query: "Test")
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["Test", "Test"])
    }

    /// Context near the start of the body must not run off the front — it should clamp to 0
    /// rather than underflow.
    func testContextClampsAtStartOfBody() {
        let occurrences = findOccurrences(body: "needle rest of body", query: "needle")
        XCTAssertEqual(occurrences.count, 1)
        XCTAssertTrue(occurrences[0].context.hasPrefix("needle"))
    }

    /// A needle longer than the haystack must not crash the substring scan.
    func testNeedleLongerThanBodyFindsNothing() {
        XCTAssertTrue(findOccurrences(body: "short", query: "a needle longer than the body").isEmpty)
    }

    func testNoOccurrenceWhenQueryIsAbsent() {
        XCTAssertTrue(findOccurrences(body: "nothing relevant here", query: "zzz").isEmpty)
    }
}
