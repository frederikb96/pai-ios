import XCTest

@testable import PAIKit

/// `EdgeFollowLatch` is the one place a "reasonable implementer" collapses two thresholds into
/// one and reintroduces the bug the web spent real time on: a short flick up re-pinning on the
/// very next scroll sample, snapping the view straight back down.
final class TranscriptEdgeFollowTests: XCTestCase {

    func testStartsPinnedByDefault() {
        XCTAssertTrue(EdgeFollowLatch().isPinned)
    }

    func testADeliberateScrollAwayUnpinsRegardlessOfDistance() {
        var latch = EdgeFollowLatch()
        latch.recordScrollAway()
        XCTAssertFalse(latch.isPinned)
    }

    /// This is the bug the asymmetric thresholds exist to prevent: a distance between the two
    /// thresholds must not re-pin, or a short flick up would be pulled straight back down.
    func testDistanceBetweenTheTwoThresholdsDoesNotRepin() {
        var latch = EdgeFollowLatch()
        latch.recordScrollAway()

        latch.recordDistanceFromBottom(30, hasNewer: false, byReader: true)  // < pinThreshold(70), > repinThreshold(4)

        XCTAssertFalse(latch.isPinned, "a mid-range distance should not have re-armed the latch")
    }

    func testOnlyComingWithinTheRepinThresholdReArms() {
        var latch = EdgeFollowLatch()
        latch.recordScrollAway()

        latch.recordDistanceFromBottom(4, hasNewer: false, byReader: true)

        XCTAssertTrue(latch.isPinned)
    }

    /// The notification bug: a jump easing away from the bottom samples a distance of zero on its
    /// first frames, and a jump to a target in the last screen is clamped onto the bottom. Either
    /// re-armed following, and the next live event carried the reader back down off the message
    /// they had just been taken to.
    func testTheAppPassingThroughTheBottomDoesNotRepin() {
        var latch = EdgeFollowLatch(isPinned: false)

        latch.recordDistanceFromBottom(0, hasNewer: false, byReader: false)

        XCTAssertFalse(latch.isPinned, "only the reader returning to the end may hand following back")
    }

    /// The whole path a jump takes, through the same two values the transcript feeds: a reader
    /// who flings to the bottom re-pins; the app's own jump afterwards cannot, even though it
    /// samples the same distance the moment it starts.
    func testAJumpAfterAFlingDoesNotInheritTheReadersMotion() {
        var motion = TranscriptReaderMotion()
        var latch = EdgeFollowLatch(isPinned: false)

        motion.beganDragging()
        motion.endedDragging(willDecelerate: true)
        latch.recordDistanceFromBottom(0, hasNewer: false, byReader: motion.isReaderDriven)
        XCTAssertTrue(latch.isPinned, "a fling that ends at the bottom is the reader returning")

        latch.recordScrollAway()
        motion.appScrolled()
        latch.recordDistanceFromBottom(0, hasNewer: false, byReader: motion.isReaderDriven)
        XCTAssertFalse(latch.isPinned, "a jump interrupting the fling must not count as the reader")
    }

    func testReaderMotionEndsOnlyWhenTheDragAndItsDecelerationBothHave() {
        var motion = TranscriptReaderMotion()
        motion.beganDragging()
        motion.endedDragging(willDecelerate: true)
        XCTAssertTrue(motion.isReaderDriven)

        motion.endedDecelerating()
        XCTAssertFalse(motion.isReaderDriven)

        motion.beganDragging()
        motion.endedDragging(willDecelerate: false)
        XCTAssertFalse(motion.isReaderDriven)
    }

    /// Growth alone (content appended while the reader is scrolled up) must never re-pin — only
    /// an actual approach to the bottom should. A sample reporting the SAME distance twice must
    /// not accidentally look like "coming closer".
    func testAlreadyPinnedIgnoresFurtherDistanceSamples() {
        var latch = EdgeFollowLatch()
        latch.recordDistanceFromBottom(500, hasNewer: false, byReader: true)
        XCTAssertTrue(latch.isPinned, "growth while pinned must never unpin it")
    }

    /// The bug a notification deep link into old history hit: landing leaves little of the
    /// window's own "after" half loaded, so the distance to the bottom of what is loaded reads
    /// small even though real conversation continues well past it. Without this guard, that
    /// sample re-pins the latch, and every SSE event and newer-page fetch that follows then drags
    /// the reader toward the true tail in steps.
    func testHasNewerBlocksRepinEvenWithinTheThreshold() {
        var latch = EdgeFollowLatch()
        latch.recordScrollAway()

        latch.recordDistanceFromBottom(0, hasNewer: true, byReader: true)

        XCTAssertFalse(latch.isPinned, "the bottom of an un-caught-up window must not count as the live edge")
    }

    /// Once paging has caught the window up to the true tail, geometry is trustworthy again.
    func testRepinsNormallyOnceHasNewerClears() {
        var latch = EdgeFollowLatch()
        latch.recordScrollAway()

        latch.recordDistanceFromBottom(0, hasNewer: false, byReader: true)

        XCTAssertTrue(latch.isPinned)
    }

    /// A latch pinned before the window stopped being the tail must not survive to the next
    /// stick decision — only a window at the tail may keep it.
    func testAWindowWithNewerContentReleasesAnAlreadyPinnedLatch() {
        var latch = EdgeFollowLatch(isPinned: true)
        latch.recordWindow(hasNewer: false)
        XCTAssertTrue(latch.isPinned)

        latch.recordWindow(hasNewer: true)
        XCTAssertFalse(latch.isPinned)
    }

    // MARK: - isAtLiveEdge (stateless)

    func testIsAtLiveEdgeIsPureGeometryIndependentOfPinnedState() {
        XCTAssertTrue(EdgeFollowLatch.isAtLiveEdge(distanceFromBottom: EdgeFollowLatch.pinThreshold))
        XCTAssertFalse(EdgeFollowLatch.isAtLiveEdge(distanceFromBottom: EdgeFollowLatch.pinThreshold + 1))
    }

    /// The subtlest distinction in the whole model: a latch that has been deliberately unpinned
    /// can still sit at a position that is geometrically "at the edge" — the two questions must
    /// not be conflated into one flag.
    func testAtLiveEdgeCanDisagreeWithIsPinned() {
        var latch = EdgeFollowLatch()
        latch.recordScrollAway()

        XCTAssertFalse(latch.isPinned)
        XCTAssertTrue(
            EdgeFollowLatch.isAtLiveEdge(distanceFromBottom: 0), "geometry alone should still report the edge")
    }
}
