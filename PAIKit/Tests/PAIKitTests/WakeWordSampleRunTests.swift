import XCTest

@testable import PAIKit

final class WakeWordSampleRunTests: XCTestCase {

    private func sample(_ label: String) -> WakeWordSample {
        WakeWordSample(
            id: label, kind: .positive, label: "run", fileName: "\(label).wav", recordedAtMs: 0, durationMs: 800,
            sampleRate: 48000, microphoneRoute: "iPhone Microphone")
    }

    func testStartingOpensTheFirstTakeWithNoCompletedSamplesYet() {
        let run = WakeWordSampleRun(kind: .positive, label: "loud")
        XCTAssertEqual(run.currentTakeIndex, 1)
        XCTAssertTrue(run.completedSamples.isEmpty)
    }

    func testNextAppendsTheFinishedTakeAndAdvancesTheIndex() throws {
        var run = WakeWordSampleRun(kind: .positive, label: "loud")
        let index = try run.next(finishing: sample("a"))
        XCTAssertEqual(index, 2)
        XCTAssertEqual(run.currentTakeIndex, 2)
        XCTAssertEqual(run.completedSamples.map(\.id), ["a"])
    }

    /// A take that produced no audio (an instant double-tap) must not pollute the manifest with a
    /// zero-content entry, but the run still has to move on to a fresh take.
    func testNextWithNoSampleAdvancesTheIndexWithoutAppendingAnything() throws {
        var run = WakeWordSampleRun(kind: .positive, label: "loud")
        let index = try run.next(finishing: nil)
        XCTAssertEqual(index, 2)
        XCTAssertTrue(run.completedSamples.isEmpty)
    }

    /// Three takes, not two — the minimum that can actually catch a swapped or dropped element,
    /// since two in the wrong order can look identical to two in the right one under a weaker
    /// assertion.
    func testCompletedSamplesStayInRecordingOrderAcrossSeveralTakes() throws {
        var run = WakeWordSampleRun(kind: .positive, label: "loud")
        try run.next(finishing: sample("a"))
        try run.next(finishing: sample("b"))
        try run.stop(finishing: sample("c"))
        XCTAssertEqual(run.completedSamples.map(\.id), ["a", "b", "c"])
    }

    func testStopAppendsTheFinalTakeAndClosesTheRun() throws {
        var run = WakeWordSampleRun(kind: .negative, label: "ambient")
        try run.stop(finishing: sample("z"))
        XCTAssertNil(run.currentTakeIndex)
        XCTAssertEqual(run.completedSamples.map(\.id), ["z"])
    }

    func testNextAfterStopThrows() throws {
        var run = WakeWordSampleRun(kind: .positive, label: "loud")
        try run.stop(finishing: nil)
        XCTAssertThrowsError(try run.next(finishing: nil)) { error in
            XCTAssertEqual(error as? WakeWordSampleRun.RunError, .notRunning)
        }
    }

    func testStopAfterStopThrows() throws {
        var run = WakeWordSampleRun(kind: .positive, label: "loud")
        try run.stop(finishing: nil)
        XCTAssertThrowsError(try run.stop(finishing: nil)) { error in
            XCTAssertEqual(error as? WakeWordSampleRun.RunError, .notRunning)
        }
    }
}
