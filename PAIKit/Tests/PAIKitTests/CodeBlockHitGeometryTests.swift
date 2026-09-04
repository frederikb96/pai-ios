import Foundation
import XCTest

@testable import PAIKit

final class CodeBlockHitGeometryTests: XCTestCase {

    func testHitOnTheFirstLineIsLineZero() {
        let code = "one\ntwo\nthree"
        let position = CodeBlockHitGeometry.position(of: NSRange(location: 1, length: 1), in: code)
        XCTAssertEqual(position.line, 0)
        XCTAssertEqual(position.column, 1)
    }

    func testHitOnASubsequentLineCountsEveryNewlineBeforeIt() {
        let code = "one\ntwo\nthree"
        // "three" starts at UTF-16 offset 8 ("one\n" = 4, "two\n" = 4 more); "r" is one further.
        let position = CodeBlockHitGeometry.position(of: NSRange(location: 9, length: 1), in: code)
        XCTAssertEqual(position.line, 2)
        XCTAssertEqual(position.column, 1)
    }

    func testColumnResetsAtTheStartOfEachLine() {
        let code = "abc\ndef"
        let position = CodeBlockHitGeometry.position(of: NSRange(location: 4, length: 1), in: code)
        XCTAssertEqual(position.line, 1)
        XCTAssertEqual(position.column, 0, "the first character of the second line is column 0, not a running total")
    }

    /// A range past the end of the text degrades to the last valid position rather than crashing
    /// — the same defensive clamp `TranscriptRowLayout.blockOffset` already applies to a stale
    /// index (see that function's own doc comment).
    func testRangeBeyondTheTextClampsRatherThanCrashing() {
        let code = "one\ntwo"
        let position = CodeBlockHitGeometry.position(of: NSRange(location: 999, length: 1), in: code)
        XCTAssertEqual(position.line, 1)
        XCTAssertEqual(position.column, 3)
    }

    func testEmptyCodeIsLineZeroColumnZero() {
        let position = CodeBlockHitGeometry.position(of: NSRange(location: 0, length: 0), in: "")
        XCTAssertEqual(position.line, 0)
        XCTAssertEqual(position.column, 0)
    }
}
