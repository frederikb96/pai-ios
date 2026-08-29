import XCTest

@testable import PAIKit

final class TranscriptBootstrapBackoffTests: XCTestCase {

    func testFirstDelayIsTheInitialValue() {
        var backoff = TranscriptBootstrapBackoff()
        XCTAssertEqual(backoff.next(), .seconds(2))
    }

    func testDelayDoublesEachCall() {
        var backoff = TranscriptBootstrapBackoff()
        XCTAssertEqual(backoff.next(), .seconds(2))
        XCTAssertEqual(backoff.next(), .seconds(4))
        XCTAssertEqual(backoff.next(), .seconds(8))
    }

    func testDelayCapsAtTheMaximumAndStaysThere() {
        var backoff = TranscriptBootstrapBackoff()
        for _ in 0..<10 { _ = backoff.next() }
        XCTAssertEqual(backoff.next(), .seconds(30))
        XCTAssertEqual(backoff.next(), .seconds(30), "the schedule must stay capped rather than overflow past it")
    }
}
