import XCTest

@testable import PAIKit

final class PathRegainFilterTests: XCTestCase {

    private func regains(_ updates: [Bool]) -> [Bool] {
        var filter = PathRegainFilter()
        return updates.map { filter.regained(satisfied: $0) }
    }

    func testARunOfSatisfiedUpdatesIsNotARegain() {
        XCTAssertEqual(regains([true, true, true, true]), [false, false, false, false])
    }

    func testOnlyTheUpdateAfterAnUnsatisfiedOneIsARegain() {
        XCTAssertEqual(
            regains([true, false, false, true, true, false, true]),
            [false, false, false, true, false, false, true])
    }

    func testStartingUnsatisfiedThenSatisfiedIsARegain() {
        XCTAssertEqual(regains([false, true, true]), [false, true, false])
    }
}
