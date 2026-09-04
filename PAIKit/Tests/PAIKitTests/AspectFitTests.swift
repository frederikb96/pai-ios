import XCTest

@testable import PAIKit

final class AspectFitTests: XCTestCase {

    /// A wide image fitting into a taller box is constrained by width, not height — the classic
    /// "letterboxed" case, and the one a naive `height / height` shortcut gets backwards.
    func testWideImageIsConstrainedByWidth() {
        let scale = AspectFit.scale(fitting: (width: 2000, height: 1000), into: (width: 400, height: 800))
        XCTAssertEqual(scale, 0.2, accuracy: 0.0001)
    }

    /// A tall image fitting into a wider box is constrained by height, the mirror case.
    func testTallImageIsConstrainedByHeight() {
        let scale = AspectFit.scale(fitting: (width: 1000, height: 2000), into: (width: 800, height: 400))
        XCTAssertEqual(scale, 0.2, accuracy: 0.0001)
    }

    /// A square image in a square box needs no scaling at all — the contrast that shows the
    /// formula isn't just always picking the smaller dimension's raw ratio by coincidence.
    func testSquareIntoSquareIsUnscaled() {
        XCTAssertEqual(AspectFit.scale(fitting: (width: 500, height: 500), into: (width: 500, height: 500)), 1)
    }

    /// A zero-sized input has no valid scale — `1` is the documented fallback, never a crash from
    /// dividing by zero.
    func testDegenerateInputFallsBackToOneRatherThanDividingByZero() {
        XCTAssertEqual(AspectFit.scale(fitting: (width: 0, height: 100), into: (width: 400, height: 400)), 1)
        XCTAssertEqual(AspectFit.scale(fitting: (width: 100, height: 100), into: (width: 0, height: 400)), 1)
    }
}
