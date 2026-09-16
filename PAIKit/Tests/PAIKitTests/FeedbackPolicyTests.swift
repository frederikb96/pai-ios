import XCTest
@testable import PAIKit

/// One test per row of the design's connection-health-feedback table, plus the rate limits with
/// a stepped clock — `FeedbackPolicy` is a pure value, so every test drives it directly with
/// literal `Date`s rather than sleeping.
final class FeedbackPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Health-episode events (connectionDropped/serverNotice/mintFailed/captureRestarted/ttsDropped)

    func testConnectionDroppedOpensAnEpisodeWithDropCueAndPost() {
        var policy = FeedbackPolicy()
        let action = policy.decide(.connectionDropped(reason: nil), now: t0)
        XCTAssertEqual(action.cue, .drop)
        XCTAssertEqual(action.notify?.disposition, .post)
        XCTAssertEqual(action.notify?.key, "health")
        XCTAssertEqual(action.notify?.episodeDropCount, 1)
    }

    func testServerNoticeBehavesLikeADrop() {
        var policy = FeedbackPolicy()
        let action = policy.decide(.serverNotice("resource_exhausted"), now: t0)
        XCTAssertEqual(action.cue, .drop)
        XCTAssertEqual(action.notify?.disposition, .post)
    }

    func testMintFailedBehavesLikeADrop() {
        var policy = FeedbackPolicy()
        let action = policy.decide(.mintFailed, now: t0)
        XCTAssertEqual(action.cue, .drop)
        XCTAssertEqual(action.notify?.disposition, .post)
    }

    func testCaptureRestartedInsideAnOpenEpisodeUpdatesWithoutReplayingTheCue() {
        var policy = FeedbackPolicy()
        _ = policy.decide(.connectionDropped(reason: nil), now: t0)
        // Past the 60s still-unstable throttle, so this second event is actually due to notify.
        let action = policy.decide(.captureRestarted, now: t0.addingTimeInterval(61))
        XCTAssertNil(action.cue)
        XCTAssertEqual(action.notify?.disposition, .update)
        XCTAssertEqual(action.notify?.episodeDropCount, 2)
    }

    func testTtsDroppedSharesTheHealthEpisode() {
        var policy = FeedbackPolicy()
        _ = policy.decide(.connectionDropped(reason: nil), now: t0)
        let action = policy.decide(.ttsDropped, now: t0.addingTimeInterval(61))
        XCTAssertNil(action.cue, "a repeat drop-class event inside the same episode never replays the drop cue")
        XCTAssertEqual(action.notify?.key, "health")
    }

    // MARK: - Never-per-flap: the cue plays once at episode start, not on every flap

    func testRepeatedFlapsWithinAnEpisodeNeverReplayTheDropCue() {
        var policy = FeedbackPolicy()
        _ = policy.decide(.connectionDropped(reason: nil), now: t0)
        for offset in 1...5 {
            let action = policy.decide(.connectionDropped(reason: nil), now: t0.addingTimeInterval(Double(offset) * 3))
            XCTAssertNil(action.cue, "flap \(offset) replayed the drop cue")
        }
    }

    // MARK: - The still-unstable notification throttle, with a stepped clock

    func testNotificationUpdateIsThrottledTo60Seconds() {
        var policy = FeedbackPolicy()
        _ = policy.decide(.connectionDropped(reason: nil), now: t0)

        let tooSoon = policy.decide(.connectionDropped(reason: nil), now: t0.addingTimeInterval(30))
        XCTAssertNil(tooSoon.notify, "an update inside the 60s window should have been suppressed")

        let dueNow = policy.decide(.connectionDropped(reason: nil), now: t0.addingTimeInterval(61))
        XCTAssertEqual(dueNow.notify?.disposition, .update)
        XCTAssertEqual(dueNow.notify?.episodeDropCount, 3, "the drop count keeps accumulating even while suppressed")
    }

    func testGapOpenedUpdatesOnTheSameThrottleAndNeverCues() {
        var policy = FeedbackPolicy()
        _ = policy.decide(.connectionDropped(reason: nil), now: t0)

        let immediate = policy.decide(.gapOpened, now: t0.addingTimeInterval(1))
        XCTAssertNil(immediate.cue)
        XCTAssertNil(immediate.notify, "throttled — the drop's own post just fired a second ago")

        let dueNow = policy.decide(.gapOpened, now: t0.addingTimeInterval(61))
        XCTAssertNil(dueNow.cue)
        XCTAssertEqual(dueNow.notify?.disposition, .update)
    }

    func testGapOpenedWithNoOpenEpisodeIsSilent() {
        var policy = FeedbackPolicy()
        let action = policy.decide(.gapOpened, now: t0)
        XCTAssertNil(action.cue)
        XCTAssertNil(action.notify)
    }

    // MARK: - Reconnect closes the episode, once, and reports how many drops it took

    func testReconnectedClosesTheEpisodeWithTheReconnectCueAndTheFinalDropCount() {
        var policy = FeedbackPolicy()
        _ = policy.decide(.connectionDropped(reason: nil), now: t0)
        _ = policy.decide(.connectionDropped(reason: nil), now: t0.addingTimeInterval(1))
        let action = policy.decide(.reconnected, now: t0.addingTimeInterval(2))
        XCTAssertEqual(action.cue, .reconnect)
        XCTAssertEqual(action.notify?.disposition, .update)
        XCTAssertEqual(action.notify?.episodeDropCount, 2)
    }

    func testReconnectedWithNoOpenEpisodeIsSilent() {
        var policy = FeedbackPolicy()
        let action = policy.decide(.reconnected, now: t0)
        XCTAssertNil(action.cue, "the very first connect is not a recovery from anything")
        XCTAssertNil(action.notify)
    }

    func testANewDropAfterReconnectStartsAFreshEpisode() {
        var policy = FeedbackPolicy()
        _ = policy.decide(.connectionDropped(reason: nil), now: t0)
        _ = policy.decide(.reconnected, now: t0.addingTimeInterval(1))
        let action = policy.decide(.connectionDropped(reason: nil), now: t0.addingTimeInterval(2))
        XCTAssertEqual(action.cue, .drop, "a drop after the episode closed must cue again, not be swallowed as a flap")
        XCTAssertEqual(action.notify?.episodeDropCount, 1)
    }

    func testTtsReconnectedClosesTheSharedEpisode() {
        var policy = FeedbackPolicy()
        _ = policy.decide(.ttsDropped, now: t0)
        let action = policy.decide(.ttsReconnected, now: t0.addingTimeInterval(1))
        XCTAssertEqual(action.cue, .reconnect)
        XCTAssertEqual(action.notify?.disposition, .update)
    }

    // MARK: - Healed clears standing errors

    func testBackfillCompletedPlaysHealedAndUpdates() {
        var policy = FeedbackPolicy()
        let action = policy.decide(.backfillCompleted, now: t0)
        XCTAssertEqual(action.cue, .healed)
        XCTAssertEqual(action.notify?.disposition, .update)
    }

    func testBackfillCompletedClearsAPreviouslyFiredCauseSoItCanFireAgain() {
        var policy = FeedbackPolicy()
        let first = policy.decide(.backfillFailed, now: t0)
        XCTAssertNotNil(first.notify, "the first backfillFailed for this take should fire")

        _ = policy.decide(.backfillCompleted, now: t0.addingTimeInterval(1))

        let afterHeal = policy.decide(.backfillFailed, now: t0.addingTimeInterval(2))
        XCTAssertNotNil(afterHeal.notify, "a fresh failure after healing is a new problem, not a repeat of the old one")
    }

    // MARK: - Standalone, once-per-cause notifications

    func testBackfillFailedFiresOnceThenIsSuppressed() {
        var policy = FeedbackPolicy()
        let first = policy.decide(.backfillFailed, now: t0)
        XCTAssertEqual(first.cue, .error)
        XCTAssertEqual(first.notify?.disposition, .post)
        XCTAssertEqual(first.notify?.key, "backfillFailed")

        let second = policy.decide(.backfillFailed, now: t0.addingTimeInterval(1))
        XCTAssertNil(second.cue)
        XCTAssertNil(second.notify, "error at most once per cause per take")
    }

    func testFatalProtocolErrorIsDedupedPerDistinctReason() {
        var policy = FeedbackPolicy()
        let quota = policy.decide(.fatalProtocolError("quota_exceeded"), now: t0)
        XCTAssertEqual(quota.notify?.disposition, .post)

        let quotaAgain = policy.decide(.fatalProtocolError("quota_exceeded"), now: t0.addingTimeInterval(1))
        XCTAssertNil(quotaAgain.notify, "the same reason must not re-fire")

        let auth = policy.decide(.fatalProtocolError("auth_error"), now: t0.addingTimeInterval(2))
        XCTAssertEqual(auth.notify?.disposition, .post, "a distinct reason is a distinct cause")
    }

    func testCaptureGaveUpFiresOncePerTake() {
        var policy = FeedbackPolicy()
        let first = policy.decide(.captureGaveUp, now: t0)
        XCTAssertEqual(first.cue, .error)
        XCTAssertEqual(first.notify?.disposition, .post)

        let second = policy.decide(.captureGaveUp, now: t0.addingTimeInterval(1))
        XCTAssertNil(second.notify)
    }

    func testReplyNotSpokenIsNeverDeduped() {
        var policy = FeedbackPolicy()
        let first = policy.decide(.replyNotSpoken, now: t0)
        let second = policy.decide(.replyNotSpoken, now: t0.addingTimeInterval(1))
        XCTAssertEqual(first.notify?.disposition, .post)
        XCTAssertEqual(second.notify?.disposition, .post, "each failed reply names a different message")
    }

    // MARK: - Cue-only, no-notification events

    func testInterruptionPausedPlaysPauseWithNoNotification() {
        var policy = FeedbackPolicy()
        let action = policy.decide(.interruptionPaused, now: t0)
        XCTAssertEqual(action.cue, .pause)
        XCTAssertNil(action.notify, "he caused it")
    }

    func testInterruptionResumedReusesTheReconnectCueWithNoNotification() {
        var policy = FeedbackPolicy()
        let action = policy.decide(.interruptionResumed, now: t0)
        XCTAssertEqual(action.cue, .reconnect)
        XCTAssertNil(action.notify)
    }

    // MARK: - Commands are exempt from every rate limit

    func testCommandRecognizedAlwaysCuesEvenRepeatedInstantly() {
        var policy = FeedbackPolicy()
        for _ in 0..<5 {
            let action = policy.decide(.commandRecognized(.send), now: t0)
            XCTAssertEqual(action.cue, .command(.send))
            XCTAssertNil(action.notify)
        }
    }

    func testDifferentCommandsProduceDifferentCues() {
        var policy = FeedbackPolicy()
        XCTAssertEqual(policy.decide(.commandRecognized(.start), now: t0).cue, .command(.start))
        XCTAssertEqual(policy.decide(.commandRecognized(.end), now: t0).cue, .command(.end))
    }

    // MARK: - A missing offline command model degrades clearly, once per command per take

    func testCommandModelMissingFiresOncePerCommandPerTake() {
        var policy = FeedbackPolicy()
        let first = policy.decide(.commandModelMissing(.start), now: t0)
        XCTAssertEqual(first.cue, .error)
        XCTAssertEqual(first.notify?.disposition, .post)

        let second = policy.decide(.commandModelMissing(.start), now: t0.addingTimeInterval(1))
        XCTAssertNil(second.notify)

        // A different command missing its model is its own, separate notice.
        let third = policy.decide(.commandModelMissing(.stop), now: t0.addingTimeInterval(2))
        XCTAssertEqual(third.notify?.disposition, .post)
    }
}
