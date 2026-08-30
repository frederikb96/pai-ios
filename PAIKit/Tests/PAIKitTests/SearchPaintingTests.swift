import Foundation
import XCTest

@testable import PAIKit

final class SearchPaintingTests: XCTestCase {

    func testNoHighlightsProducesOneUnemphasizedSegmentCoveringEverything() {
        let segments = TranscriptSearchPainting.segments(length: 10, highlights: [])
        XCTAssertEqual(segments, [TranscriptSearchSegment(range: NSRange(location: 0, length: 10), emphasis: .none)])
    }

    func testZeroLengthProducesNoSegmentsRegardlessOfHighlights() {
        let segments = TranscriptSearchPainting.segments(
            length: 0, highlights: [(range: NSRange(location: 0, length: 5), isCurrent: false)])
        XCTAssertEqual(segments, [])
    }

    /// A hit in the middle of the text must leave the untouched text before and after it as its
    /// own unemphasized segments — nothing here may insert or drop a character, only mark it.
    func testAHitInTheMiddleProducesThreeSegments() {
        let segments = TranscriptSearchPainting.segments(
            length: 10, highlights: [(range: NSRange(location: 3, length: 2), isCurrent: false)])

        XCTAssertEqual(
            segments,
            [
                TranscriptSearchSegment(range: NSRange(location: 0, length: 3), emphasis: .none),
                TranscriptSearchSegment(range: NSRange(location: 3, length: 2), emphasis: .hit),
                TranscriptSearchSegment(range: NSRange(location: 5, length: 5), emphasis: .none),
            ])
    }

    func testTheCurrentHitIsMarkedDistinctlyFromAnOrdinaryHit() {
        let segments = TranscriptSearchPainting.segments(
            length: 4, highlights: [(range: NSRange(location: 0, length: 4), isCurrent: true)])
        XCTAssertEqual(
            segments, [TranscriptSearchSegment(range: NSRange(location: 0, length: 4), emphasis: .currentHit)])
    }

    /// Every segment boundary the caller sees must reconstruct exactly `[0, length)` with no gap
    /// and no overlap — the property that makes it safe to render each segment as an independent
    /// substring and reassemble them in order.
    func testSegmentsAreContiguousAndCoverTheWholeLength() {
        let segments = TranscriptSearchPainting.segments(
            length: 20,
            highlights: [
                (range: NSRange(location: 2, length: 3), isCurrent: false),
                (range: NSRange(location: 10, length: 4), isCurrent: true),
            ])

        var cursor = 0
        for segment in segments {
            XCTAssertEqual(segment.range.location, cursor)
            cursor += segment.range.length
        }
        XCTAssertEqual(cursor, 20)
    }

    /// A highlight range extending past the text's own length (stale data from a query that
    /// matched before an edit) must be clipped rather than producing a segment nothing can
    /// substring — the failure mode a view crashing on `NSString.substring(with:)` would hit.
    func testAHighlightRangeExtendingPastTheEndIsClippedToTheLength() {
        let segments = TranscriptSearchPainting.segments(
            length: 5, highlights: [(range: NSRange(location: 3, length: 10), isCurrent: false)])

        XCTAssertEqual(
            segments,
            [
                TranscriptSearchSegment(range: NSRange(location: 0, length: 3), emphasis: .none),
                TranscriptSearchSegment(range: NSRange(location: 3, length: 2), emphasis: .hit),
            ])
    }

    /// Input need not be sorted — a caller filtering hits by message id has no reason to also
    /// sort them by position, so this must not assume it was handed a sorted array.
    func testHighlightsOutOfOrderAreStillPlacedCorrectly() {
        let segments = TranscriptSearchPainting.segments(
            length: 10,
            highlights: [
                (range: NSRange(location: 7, length: 2), isCurrent: false),
                (range: NSRange(location: 1, length: 2), isCurrent: false),
            ])

        XCTAssertEqual(
            segments.map(\.range),
            [
                NSRange(location: 0, length: 1),
                NSRange(location: 1, length: 2),
                NSRange(location: 3, length: 4),
                NSRange(location: 7, length: 2),
                NSRange(location: 9, length: 1),
            ])
    }
}
