import XCTest

@testable import PAIKit

/// `TranscriptLanding.rowId(forTarget:in:)` is what keeps a jump from silently doing nothing when
/// its target id has no row of its own (a boundary id that routed `.hidden`/`.none`) — see that
/// function's own doc comment for why the gap exists.
final class TranscriptLandingTests: XCTestCase {

    func testTargetPresentLandsOnItself() {
        XCTAssertEqual(TranscriptLanding.rowId(forTarget: 20, in: [10, 20, 30]), 20)
    }

    func testTargetAbsentLandsOnTheNearestFollowingRow() {
        XCTAssertEqual(TranscriptLanding.rowId(forTarget: 15, in: [10, 20, 30]), 20)
    }

    func testTargetPastEveryLoadedRowLandsNowhere() {
        XCTAssertNil(TranscriptLanding.rowId(forTarget: 40, in: [10, 20, 30]))
    }

    /// The boundary case a caller could get backwards: a target *before* everything loaded still
    /// has a legitimate following row — this must not be confused with "past the end".
    func testTargetBeforeEveryLoadedRowLandsOnTheFirstOne() {
        XCTAssertEqual(TranscriptLanding.rowId(forTarget: 1, in: [10, 20, 30]), 10)
    }

    func testEmptyWindowLandsNowhere() {
        XCTAssertNil(TranscriptLanding.rowId(forTarget: 20, in: []))
    }
}
