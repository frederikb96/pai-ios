import XCTest
@testable import PAIKit

/// A chip that should sit beside its label lands on a row of its own, or a long text runs off the
/// edge instead of wrapping — both read as a rendering glitch rather than a layout rule.
final class InlineFlowTests: XCTestCase {

    /// Ideal sizes per piece; offered a narrower width, a piece wraps to it and grows taller.
    private func measure(_ ideal: [(width: Double, height: Double)]) -> (Int, Double?) -> (
        width: Double, height: Double
    ) {
        { index, proposed in
            let size = ideal[index]
            guard let proposed, proposed < size.width else { return size }
            return (proposed, size.height * (size.width / proposed).rounded(.up))
        }
    }

    func testAPieceThatFitsBesideTheLastStaysOnItsRow() {
        let result = InlineFlow.arrange(
            count: 2, width: 96, spacing: 6, lineSpacing: 4, measure: measure([(50, 20), (40, 20)]))
        XCTAssertEqual(result.frames.map(\.y), [0, 0])
        XCTAssertEqual(result.frames.map(\.x), [0, 56])
        XCTAssertEqual(result.height, 20)
    }

    func testAPieceOnePointTooWideStartsTheNextRow() {
        let result = InlineFlow.arrange(
            count: 2, width: 95, spacing: 6, lineSpacing: 4, measure: measure([(50, 20), (40, 20)]))
        XCTAssertEqual(result.frames.map(\.x), [0, 0])
        XCTAssertEqual(result.frames.map(\.y), [0, 24])
        XCTAssertEqual(result.height, 44)
    }

    /// A text longer than a row wraps at the row's width rather than overflowing it, and the chip
    /// after it goes below.
    func testALongPieceWrapsToTheRowAndTheNextGoesBelow() {
        let result = InlineFlow.arrange(
            count: 2, width: 100, spacing: 6, lineSpacing: 4, measure: measure([(250, 20), (40, 30)]))
        XCTAssertEqual(result.frames[0], InlineFlow.Frame(x: 0, y: 0, width: 100, height: 60))
        XCTAssertEqual(result.frames[1], InlineFlow.Frame(x: 0, y: 64, width: 40, height: 30))
        XCTAssertEqual(result.width, 100)
    }

    func testPiecesInARowAreCentredOnTheTallest() {
        let result = InlineFlow.arrange(
            count: 2, width: 200, spacing: 6, lineSpacing: 4, measure: measure([(50, 20), (40, 32)]))
        XCTAssertEqual(result.frames.map(\.y), [6, 0])
        XCTAssertEqual(result.height, 32)
    }
}
