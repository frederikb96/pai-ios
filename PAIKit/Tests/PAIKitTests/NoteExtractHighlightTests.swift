import Foundation
import XCTest

@testable import PAIKit

final class NoteExtractHighlightTests: XCTestCase {

    func testHighlightsFromCharacterOffsetInUtf16Units() {
        let ranges = NoteExtractHighlight.ranges(extract: "hello world", offsets: [6])
        XCTAssertEqual(ranges, [NSRange(location: 6, length: 5)])
    }

    /// Without the character→UTF-16 bridge, an offset counted in characters and read as though it
    /// were already a UTF-16 index lands short by every extra unit a surrogate pair before it
    /// costs. The German flag is one `Character` but four UTF-16 units, so a match starting right
    /// after it makes that drift visible rather than accidentally cancelling out.
    func testOffsetAfterASurrogatePairShiftsByTheExtraUtf16Units() {
        let ranges = NoteExtractHighlight.ranges(extract: "🇩🇪 hello", offsets: [2])
        XCTAssertEqual(ranges, [NSRange(location: 5, length: 5)])
    }

    /// The API reports no match length, so a hit highlights up to `maxHighlightLength`. The
    /// extract here is deliberately longer than that, so a highlight that (bug) runs all the way
    /// to the extract's end would still look plausible without asserting the exact length.
    func testHighlightIsCappedAtMaxLength() {
        let extract = String(repeating: "x", count: 100)
        let ranges = NoteExtractHighlight.ranges(extract: extract, offsets: [0])
        XCTAssertEqual(ranges, [NSRange(location: 0, length: NoteExtractHighlight.maxHighlightLength)])
    }

    /// Two matches close together must not have overlapping highlights — the first hit's span
    /// stops at the second hit's own start rather than running the full cap length into it.
    func testHighlightStopsAtTheNextOffsetRatherThanOverrunningIt() {
        let extract = String(repeating: "x", count: 100)
        let ranges = NoteExtractHighlight.ranges(extract: extract, offsets: [0, 5])
        XCTAssertEqual(ranges[0], NSRange(location: 0, length: 5))
        XCTAssertEqual(ranges[1].location, 5)
    }

    func testEmptyOffsetsProduceNoHighlights() {
        XCTAssertEqual(NoteExtractHighlight.ranges(extract: "hello", offsets: []), [])
    }

    /// A server-reported offset past the extract's own length is a server-side inconsistency this
    /// client cannot repair — it is dropped rather than crashing the whole decode.
    func testOffsetOutsideTheExtractIsDropped() {
        XCTAssertEqual(NoteExtractHighlight.ranges(extract: "hi", offsets: [50]), [])
    }
}
