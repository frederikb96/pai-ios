import XCTest

@testable import PAIKit

/// `StreamActivity.state(now:idleThreshold:stallThreshold:)` is what a status dot's truthfulness
/// rests on — these pin the exact boundaries, since an off-by-one here reads as either a dot
/// that never goes green or one that stays green through a real stall.
final class StreamActivityTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 0)

    func testNeverConnectedIsDisconnected() {
        let activity = StreamActivity()
        XCTAssertEqual(activity.state(now: epoch, idleThreshold: 5, stallThreshold: 20), .disconnected)
    }

    func testDisconnectedAfterRecordingDisconnectEvenWithAPriorEvent() {
        var activity = StreamActivity()
        activity.recordConnected(at: epoch)
        activity.recordEvent(at: epoch)
        activity.recordDisconnected()
        XCTAssertEqual(activity.state(now: epoch, idleThreshold: 5, stallThreshold: 20), .disconnected)
    }

    /// A freshly connected stream with nothing received yet must read as receiving, not
    /// immediately idle or stalled — there has not been time to be quiet yet.
    func testJustConnectedWithNoEventYetReadsAsReceiving() {
        var activity = StreamActivity()
        activity.recordConnected(at: epoch)
        XCTAssertEqual(activity.state(now: epoch, idleThreshold: 5, stallThreshold: 20), .receiving)
    }

    /// Exactly at the idle threshold is still receiving — the threshold marks where idle begins,
    /// not where receiving ends.
    func testExactlyAtIdleThresholdIsStillReceiving() {
        var activity = StreamActivity()
        activity.recordConnected(at: epoch)
        activity.recordEvent(at: epoch)
        let now = epoch.addingTimeInterval(5)
        XCTAssertEqual(activity.state(now: now, idleThreshold: 5, stallThreshold: 20), .receiving)
    }

    func testJustPastIdleThresholdBecomesIdle() {
        var activity = StreamActivity()
        activity.recordConnected(at: epoch)
        activity.recordEvent(at: epoch)
        let now = epoch.addingTimeInterval(5.001)
        guard case .idle(let elapsed) = activity.state(now: now, idleThreshold: 5, stallThreshold: 20) else {
            return XCTFail("expected .idle")
        }
        XCTAssertEqual(elapsed, 5.001, accuracy: 0.0001)
    }

    func testExactlyAtStallThresholdIsStillIdleNotStalled() {
        var activity = StreamActivity()
        activity.recordConnected(at: epoch)
        activity.recordEvent(at: epoch)
        let now = epoch.addingTimeInterval(20)
        XCTAssertEqual(activity.state(now: now, idleThreshold: 5, stallThreshold: 20), .idle(secondsSinceLastEvent: 20))
    }

    func testJustPastStallThresholdBecomesStalled() {
        var activity = StreamActivity()
        activity.recordConnected(at: epoch)
        activity.recordEvent(at: epoch)
        let now = epoch.addingTimeInterval(20.001)
        guard case .stalled(let elapsed) = activity.state(now: now, idleThreshold: 5, stallThreshold: 20) else {
            return XCTFail("expected .stalled")
        }
        XCTAssertEqual(elapsed, 20.001, accuracy: 0.0001)
    }

    /// A fresh event resets the clock even after the stream had gone stale — reconnecting or a
    /// keepalive arriving must bring the display straight back to receiving.
    func testANewEventAfterGoingStaleReturnsToReceiving() {
        var activity = StreamActivity()
        activity.recordConnected(at: epoch)
        activity.recordEvent(at: epoch)
        let laterEvent = epoch.addingTimeInterval(30)
        activity.recordEvent(at: laterEvent)
        XCTAssertEqual(activity.state(now: laterEvent, idleThreshold: 5, stallThreshold: 20), .receiving)
    }

    /// Reconnecting without a fresh event yet resets the grace period from the new connection
    /// time, not from whenever the last event before the drop happened to arrive.
    func testReconnectingResetsTheGracePeriodFromTheNewConnectionTime() {
        var activity = StreamActivity()
        activity.recordConnected(at: epoch)
        activity.recordEvent(at: epoch)
        activity.recordDisconnected()
        let reconnectedAt = epoch.addingTimeInterval(100)
        activity.recordConnected(at: reconnectedAt)
        XCTAssertEqual(activity.state(now: reconnectedAt, idleThreshold: 5, stallThreshold: 20), .receiving)
    }
}
