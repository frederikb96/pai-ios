import XCTest

@testable import PAIKit

final class WakeWordSampleRunTests: XCTestCase {

    private func take(_ id: String, index: Int) -> WakeWordPendingTake {
        WakeWordPendingTake(
            id: id, index: index, recordedAt: "2026-10-03T10:00:00Z", durationMs: 800, fileName: "\(id).wav")
    }

    func testStartingOpensTheFirstTakeWithNothingCompletedYet() {
        let run = WakeWordSampleRun(id: "r", kind: .positive, label: "loud")
        XCTAssertEqual(run.currentTakeIndex, 1)
        XCTAssertTrue(run.completedTakes.isEmpty)
    }

    /// A take that produced no audio (an instant double-tap) must not become an empty upload, but
    /// the run still moves on to a fresh take.
    func testNextWithNoTakeAdvancesWithoutAppending() throws {
        var run = WakeWordSampleRun(id: "r", kind: .positive, label: "loud")
        let index = try run.next(finishing: nil)
        XCTAssertEqual(index, 2)
        XCTAssertTrue(run.completedTakes.isEmpty)
    }

    /// Three takes, not two — the minimum that can catch a swapped or dropped element.
    func testTakesStayInRecordingOrderAcrossSeveralNexts() throws {
        var run = WakeWordSampleRun(id: "r", kind: .positive, label: "loud")
        try run.next(finishing: take("a", index: 1))
        try run.next(finishing: take("b", index: 2))
        try run.stop(finishing: take("c", index: 3))
        XCTAssertEqual(run.completedTakes.map(\.id), ["a", "b", "c"])
        XCTAssertNil(run.currentTakeIndex)
    }

    func testNothingContinuesAfterStop() throws {
        var run = WakeWordSampleRun(id: "r", kind: .negative, label: "ambient")
        try run.stop(finishing: nil)
        XCTAssertThrowsError(try run.next(finishing: nil)) { error in
            XCTAssertEqual(error as? WakeWordSampleRun.RunError, .notRunning)
        }
        XCTAssertThrowsError(try run.stop(finishing: nil))
    }
}
