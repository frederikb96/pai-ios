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

    /// `matchStart`/`matchEnd` index into `context`, not into the whole body — a caller
    /// highlighting the hit must be able to slice `context` directly with them.
    func testMatchOffsetsAreRelativeToContextNotBody() {
        let occurrences = findOccurrences(body: "needle", query: "needle")
        let occ = occurrences[0]
        let context = Array(occ.context)
        XCTAssertEqual(String(context[occ.matchStart..<occ.matchEnd]), "needle")
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
