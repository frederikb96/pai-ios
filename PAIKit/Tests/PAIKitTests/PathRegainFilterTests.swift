import XCTest

@testable import PAIKit

final class PathRegainFilterTests: XCTestCase {

    private typealias Update = (satisfied: Bool, interface: PathInterface?)

    private func news(_ updates: [Update]) -> [Bool] {
        var filter = PathRegainFilter()
        return updates.map { filter.regained(satisfied: $0.satisfied, interface: $0.interface) }
    }

    func testARunOfIdenticalSatisfiedUpdatesIsNotNews() {
        XCTAssertEqual(
            news([(true, .wifi), (true, .wifi), (true, .wifi), (true, .wifi)]), [false, false, false, false])
    }

    func testOnlyTheUpdateAfterAnUnsatisfiedOneIsARegain() {
        XCTAssertEqual(
            news([(true, .wifi), (false, nil), (false, nil), (true, .wifi), (true, .wifi), (false, nil), (true, .wifi)]
            ),
            [false, false, false, true, false, false, true])
    }

    func testStartingUnsatisfiedThenSatisfiedIsARegain() {
        XCTAssertEqual(news([(false, nil), (true, .wifi), (true, .wifi)]), [false, true, false])
    }

    func testAHandoffToAnotherInterfaceWhileStayingUpIsNews() {
        XCTAssertEqual(
            news([(true, .wifi), (true, .cellular), (true, .cellular), (true, .wifi)]),
            [false, true, false, true])
    }

    func testTheInterfaceBeforeAnOutageDoesNotCountAsAChange() {
        XCTAssertEqual(news([(true, .wifi), (false, nil), (true, .wifi)]), [false, false, true])
        XCTAssertEqual(news([(true, .wifi), (false, nil), (true, .cellular)]), [false, false, true])
    }
}
