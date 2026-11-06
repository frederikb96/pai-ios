import XCTest

@testable import PAIKit

final class PlaybackKeepAliveTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func inputs(
        outOfSight: Bool = true, autoplayOn: Bool = true, player: PlaybackStatus? = nil, working: Bool = false,
        watching: Bool = false, voiceBusy: Bool = false, otherApp: Bool = false
    ) -> PlaybackKeepAlive.Inputs {
        PlaybackKeepAlive.Inputs(
            outOfSight: outOfSight, autoplayOn: autoplayOn, player: player, autoplayWorking: working,
            autoplayWatching: watching || working, voiceBusy: voiceBusy, otherAppPlaying: otherApp)
    }

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    /// The reported fault: a reply finishes while locked and the next one arrives a few seconds
    /// later. The gap must be held so the app is still running when it does.
    func testHoldsTheGapAfterAReplyFinishes() {
        var keepAlive = PlaybackKeepAlive()
        XCTAssertTrue(keepAlive.update(inputs(player: .playing, working: true), now: at(0)))
        XCTAssertTrue(keepAlive.update(inputs(player: nil, working: true), now: at(30)))
        XCTAssertTrue(keepAlive.update(inputs(player: nil, working: false), now: at(35)))
        XCTAssertTrue(keepAlive.update(inputs(player: .loading, working: true), now: at(40)))
    }

    func testNothingIsHeldInFrontOfThePerson() {
        var keepAlive = PlaybackKeepAlive()
        XCTAssertFalse(keepAlive.update(inputs(outOfSight: false, player: .playing, working: true), now: at(0)))
    }

    func testAutoplayOffLetsTheAppSuspend() {
        var keepAlive = PlaybackKeepAlive()
        XCTAssertFalse(keepAlive.update(inputs(autoplayOn: false, player: .playing, working: true), now: at(0)))
        XCTAssertTrue(keepAlive.update(inputs(player: .playing), now: at(1)))
        XCTAssertFalse(keepAlive.update(inputs(autoplayOn: false, player: nil), now: at(2)))
    }

    func testLetsGoOnceTheSessionsStopWorking() {
        var keepAlive = PlaybackKeepAlive()
        keepAlive.update(inputs(player: .playing), now: at(0))
        XCTAssertTrue(keepAlive.update(inputs(player: nil), now: at(PlaybackKeepAlive.quietGrace)))
        XCTAssertFalse(keepAlive.update(inputs(player: nil), now: at(PlaybackKeepAlive.quietGrace + 1)))
    }

    func testAWorkingSessionExtendsTheWaitUpToTheCap() {
        var keepAlive = PlaybackKeepAlive()
        keepAlive.update(inputs(player: .playing), now: at(0))
        var second: TimeInterval = 60
        while second <= PlaybackKeepAlive.maxWait {
            XCTAssertTrue(keepAlive.update(inputs(player: nil, working: true), now: at(second)), "at \(second)s")
            second += 60
        }
        XCTAssertFalse(keepAlive.update(inputs(player: nil, working: true), now: at(second)))
    }

    func testLeavingTheScreenWhileASessionWorksHolds() {
        var keepAlive = PlaybackKeepAlive()
        XCTAssertTrue(keepAlive.update(inputs(player: nil, working: true), now: at(0)))
        XCTAssertTrue(keepAlive.update(inputs(player: nil, working: true), now: at(60)))
    }

    /// Send, then lock at once: the turn is not reported yet, but the session is being watched.
    func testLeavingTheScreenOnAWatchedSessionHoldsTheGrace() {
        var keepAlive = PlaybackKeepAlive()
        XCTAssertTrue(keepAlive.update(inputs(player: nil, watching: true), now: at(0)))
        XCTAssertTrue(keepAlive.update(inputs(player: nil, working: true), now: at(5)))
        XCTAssertTrue(
            keepAlive.update(inputs(player: .loading, working: true), now: at(PlaybackKeepAlive.quietGrace + 60)))
    }

    func testAWatchedSessionThatNeverStartsWorkingIsLetGo() {
        var keepAlive = PlaybackKeepAlive()
        keepAlive.update(inputs(player: nil, watching: true), now: at(0))
        XCTAssertTrue(keepAlive.update(inputs(player: nil, watching: true), now: at(PlaybackKeepAlive.quietGrace)))
        XCTAssertFalse(keepAlive.update(inputs(player: nil, watching: true), now: at(PlaybackKeepAlive.quietGrace + 1)))
    }

    func testLeavingTheScreenWithNothingComingHoldsNothing() {
        var keepAlive = PlaybackKeepAlive()
        XCTAssertFalse(keepAlive.update(inputs(player: nil, working: false), now: at(0)))
        // Out of sight and silent already: work that shows up now cannot start audio.
        XCTAssertFalse(keepAlive.update(inputs(player: nil, working: true), now: at(5)))
    }

    func testNeverStartsOverAnotherAppsAudio() {
        var keepAlive = PlaybackKeepAlive()
        XCTAssertFalse(keepAlive.update(inputs(player: nil, working: true, otherApp: true), now: at(0)))
    }

    func testAPausedReplyIsNotWaitedBehind() {
        var keepAlive = PlaybackKeepAlive()
        keepAlive.update(inputs(player: .playing, working: true), now: at(0))
        XCTAssertFalse(keepAlive.update(inputs(player: .paused, working: true), now: at(5)))
        XCTAssertFalse(keepAlive.update(inputs(player: .error, working: true), now: at(6)))
        // Play from the lock screen resumes the reply, and the wait after it with it.
        XCTAssertTrue(keepAlive.update(inputs(player: .playing, working: true), now: at(10)))
        XCTAssertTrue(keepAlive.update(inputs(player: nil, working: true), now: at(20)))
    }

    func testAReleasedWaitStaysEndedUntilTheAppIsInFrontAgain() {
        var keepAlive = PlaybackKeepAlive()
        keepAlive.update(inputs(player: nil, working: true), now: at(0))
        keepAlive.release()
        XCTAssertFalse(keepAlive.holding)
        XCTAssertFalse(keepAlive.update(inputs(player: nil, working: true), now: at(5)))
        keepAlive.update(inputs(outOfSight: false), now: at(10))
        XCTAssertTrue(keepAlive.update(inputs(player: nil, working: true), now: at(20)))
    }

    func testAReplyPlayingAgainEndsARelease() {
        var keepAlive = PlaybackKeepAlive()
        keepAlive.update(inputs(player: .playing, working: true), now: at(0))
        keepAlive.release()
        XCTAssertFalse(keepAlive.update(inputs(player: .paused, working: true), now: at(5)))
        XCTAssertTrue(keepAlive.update(inputs(player: .playing, working: true), now: at(60)))
        XCTAssertTrue(keepAlive.update(inputs(player: nil, working: true), now: at(90)))
    }

    func testADictationOrCallKeepsTheAudioSession() {
        var keepAlive = PlaybackKeepAlive()
        XCTAssertFalse(keepAlive.update(inputs(player: .playing, working: true, voiceBusy: true), now: at(0)))
    }

    func testOnlyAConnectedAutoplaySessionCountsAsWorking() {
        let modes = ["a": SessionPlayback(autoplay: true), "b": SessionPlayback(autoplay: false)]
        func working(processing: Set<String>, streaming: Set<String>) -> Bool {
            PlaybackKeepAlive.autoplayWorking(
                modes: modes, isProcessing: { processing.contains($0) }, isStreaming: { streaming.contains($0) })
        }
        XCTAssertTrue(working(processing: ["a"], streaming: ["a"]))
        XCTAssertFalse(working(processing: ["a"], streaming: []))
        XCTAssertFalse(working(processing: ["b"], streaming: ["b"]))
        XCTAssertFalse(working(processing: ["c"], streaming: ["c"]))
        XCTAssertTrue(PlaybackKeepAlive.autoplayWatching(modes: modes, isStreaming: { $0 == "a" }))
        XCTAssertFalse(PlaybackKeepAlive.autoplayWatching(modes: modes, isStreaming: { $0 == "b" }))
    }
}
