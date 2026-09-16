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

    func testBackfillCompletedAfterARealDropPlaysHealedAndUpdates() {
        var policy = FeedbackPolicy()
        _ = policy.decide(.connectionDropped(reason: nil), now: t0)
        _ = policy.decide(.reconnected, now: t0.addingTimeInterval(1))
        let action = policy.decide(.backfillCompleted, now: t0.addingTimeInterval(2))
        XCTAssertEqual(action.cue, .healed)
        XCTAssertEqual(action.notify?.disposition, .update)
    }

    /// The ordinary shape of a fresh cycle: a pre-connect gap opens and a backfill heals it with
    /// no connection ever actually dropping. Nothing was ever announced, so there is nothing to
    /// post a closing update to — this is the fix for the notification firing on every ordinary
    /// turn.
    func testBackfillCompletedWithNoHealthNotificationEverPostedIsSilent() {
        var policy = FeedbackPolicy()
        let action = policy.decide(.backfillCompleted, now: t0)
        XCTAssertNil(action.cue)
        XCTAssertNil(action.notify)
    }

    func testBackfillCompletedClearsAPreviouslyFiredCauseSoItCanFireAgain() {
        var policy = FeedbackPolicy()
        let first = policy.decide(.backfillFailed, now: t0)
        XCTAssertNotNil(first.notify, "the first backfillFailed for this take should fire")

        _ = policy.decide(.backfillCompleted, now: t0.addingTimeInterval(1))

        let afterHeal = policy.decide(.backfillFailed, now: t0.addingTimeInterval(2))
        XCTAssertNotNil(afterHeal.notify, "a fresh failure after healing is a new problem, not a repeat of the old one")
    }

    // MARK: - An ordinary multi-cycle call posts nothing; a real drop still does

    /// What a clean call-mode or microphone-mode cycle actually produces: the socket opening
    /// reads as unstable until proven stable (`gapOpened`), the fresh cycle then proving itself
    /// (`reconnected`), and the ordinary pre-connect gap healing (`backfillCompleted`) — none of
    /// it a real hiccup, so none of it should reach Freddy.
    func testAnOrdinaryCycleWithNoRealDropProducesNoCueOrNotification() {
        var policy = FeedbackPolicy()
        let gap = policy.decide(.gapOpened, now: t0)
        XCTAssertNil(gap.cue)
        XCTAssertNil(gap.notify)

        let reconnected = policy.decide(.reconnected, now: t0.addingTimeInterval(10))
        XCTAssertNil(reconnected.cue)
        XCTAssertNil(reconnected.notify)

        let backfill = policy.decide(.backfillCompleted, now: t0.addingTimeInterval(11))
        XCTAssertNil(backfill.cue)
        XCTAssertNil(backfill.notify)
    }

    /// The same sequence, but a real drop happened first — every step of it must still reach
    /// Freddy, ending with the backfill's own closing update to the same notification.
    func testARealDropStillProducesACueAndNotificationThroughToTheFinalBackfillUpdate() {
        var policy = FeedbackPolicy()
        let dropped = policy.decide(.connectionDropped(reason: nil), now: t0)
        XCTAssertEqual(dropped.cue, .drop)
        XCTAssertEqual(dropped.notify?.disposition, .post)

        let reconnected = policy.decide(.reconnected, now: t0.addingTimeInterval(10))
        XCTAssertEqual(reconnected.cue, .reconnect)
        XCTAssertEqual(reconnected.notify?.disposition, .update)

        let backfill = policy.decide(.backfillCompleted, now: t0.addingTimeInterval(11))
        XCTAssertEqual(backfill.cue, .healed)
        XCTAssertEqual(backfill.notify?.disposition, .update)
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

    /// A permanent rejection (an unknown voice id, a bad key) is never a drop — it dedupes by its
    /// own machine-readable reason, exactly like `fatalProtocolError`, so a second reply hitting
    /// the identical rejection does not re-notify.
    func testTtsRejectedFiresOncePerDistinctReason() {
        var policy = FeedbackPolicy()
        let first = policy.decide(.ttsRejected(reason: "voice_id_does_not_exist", message: "not found"), now: t0)
        XCTAssertEqual(first.cue, .error)
        XCTAssertEqual(first.notify?.disposition, .post)
        XCTAssertEqual(first.notify?.key, "ttsRejected:voice_id_does_not_exist")

        let second = policy.decide(
            .ttsRejected(reason: "voice_id_does_not_exist", message: "not found"), now: t0.addingTimeInterval(1))
        XCTAssertNil(second.notify, "the same reason must not re-fire")

        let different = policy.decide(
            .ttsRejected(reason: "authentication_required", message: "bad key"), now: t0.addingTimeInterval(2))
        XCTAssertEqual(different.notify?.disposition, .post, "a distinct reason is a distinct cause")
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
