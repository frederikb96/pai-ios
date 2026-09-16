import XCTest

@testable import PAIKit

final class ConnectionHealthTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 0)

    func testOfflineUntilThePathIsSatisfied() {
        var health = ConnectionHealth()
        XCTAssertEqual(health.state, .offline)
        // A socket opening before the path is even known satisfied cannot lift this above
        // offline — `pathSatisfied` is the outer gate every other input is read behind.
        XCTAssertEqual(health.handle(.socketOpened, now: start), .offline)
    }

    func testPathSatisfiedWithNoSocketYetIsConnecting() {
        var health = ConnectionHealth()
        XCTAssertEqual(health.handle(.pathSatisfied(true), now: start), .connecting)
    }

    /// The core threshold the design turns into a measured constant: a socket must stay open,
    /// have delivered something, and carry no recent failure for the full window before it counts
    /// as trustworthy.
    func testTenCleanSecondsReachesStable() {
        var health = ConnectionHealth()
        _ = health.handle(.pathSatisfied(true), now: start)
        _ = health.handle(.socketOpened, now: start)
        _ = health.handle(.socketDelivered, now: start)
        let tenSecondsLater = start.addingTimeInterval(ConnectionHealth.stableAfterSeconds)
        XCTAssertEqual(health.handle(.tick(tenSecondsLater), now: tenSecondsLater), .stable)
    }

    func testNotYetStableBeforeTheOpenDurationThresholdIsReached() {
        var health = ConnectionHealth()
        _ = health.handle(.pathSatisfied(true), now: start)
        _ = health.handle(.socketOpened, now: start)
        _ = health.handle(.socketDelivered, now: start)
        let almostTenSeconds = start.addingTimeInterval(ConnectionHealth.stableAfterSeconds - 1)
        XCTAssertEqual(health.handle(.tick(almostTenSeconds), now: almostTenSeconds), .unstable)
    }

    func testOpenSocketThatHasNeverDeliveredIsNotStable() {
        var health = ConnectionHealth()
        _ = health.handle(.pathSatisfied(true), now: start)
        _ = health.handle(.socketOpened, now: start)
        let farLater = start.addingTimeInterval(60)
        XCTAssertEqual(health.handle(.tick(farLater), now: farLater), .unstable)
    }

    /// The exact regression a 3–5s cellular flap must never produce: never enough clean time in a
    /// row to be called stable, across the full three minutes the design's own worst case names.
    func testAFlapEveryThreeToFiveSecondsForThreeMinutesNeverReachesStable() {
        var health = ConnectionHealth()
        _ = health.handle(.pathSatisfied(true), now: start)
        var now = start
        var everStable = false
        var flapSeconds: TimeInterval = 3
        while now.timeIntervalSince(start) < 180 {
            _ = health.handle(.socketOpened, now: now)
            _ = health.handle(.socketDelivered, now: now)
            let closeAt = now.addingTimeInterval(flapSeconds)
            let stateWhileOpen = health.handle(.tick(closeAt), now: closeAt)
            everStable = everStable || stateWhileOpen == .stable
            _ = health.handle(.socketClosed(reason: nil), now: closeAt)
            now = closeAt
            flapSeconds = flapSeconds == 3 ? 5 : 3
        }
        XCTAssertFalse(everStable)
        // No socket is open right after the last close — this state means "about to reconnect",
        // distinct from `.unstable`, which requires a socket currently open.
        XCTAssertEqual(health.state, .connecting)
    }

    /// A mint failure (the app's own backend hop, not the ElevenLabs socket itself) is a
    /// connection loss of the other hop and must count identically toward the recent-failure
    /// window.
    func testAMintFailureCountsAsARecentFailureJustLikeAClose() {
        var health = ConnectionHealth()
        _ = health.handle(.pathSatisfied(true), now: start)
        _ = health.handle(.socketOpened, now: start)
        _ = health.handle(.socketDelivered, now: start)
        let mintFailureAt = start.addingTimeInterval(5)
        _ = health.handle(.mintFailed, now: mintFailureAt)
        let tenSecondsAfterOpen = start.addingTimeInterval(ConnectionHealth.stableAfterSeconds)
        XCTAssertEqual(
            health.handle(.tick(tenSecondsAfterOpen), now: tenSecondsAfterOpen), .unstable,
            "a failure inside the last 30s must hold the state at unstable"
        )
        let wellPastTheWindow = mintFailureAt.addingTimeInterval(ConnectionHealth.recentFailureWindowSeconds + 1)
        XCTAssertEqual(health.handle(.tick(wellPastTheWindow), now: wellPastTheWindow), .stable)
    }

    /// While the path itself is unsatisfied, no open socket can make the state anything but
    /// `.offline` — this is what a caller reads before deciding whether to attempt a reconnect at
    /// all.
    func testPathUnsatisfiedOverridesAnOpenSocket() {
        var health = ConnectionHealth()
        _ = health.handle(.pathSatisfied(true), now: start)
        _ = health.handle(.socketOpened, now: start)
        _ = health.handle(.socketDelivered, now: start)
        XCTAssertEqual(health.handle(.pathSatisfied(false), now: start), .offline)
    }

    // MARK: - backfillGate

    /// The exact scenario `state` cannot answer: no take is recording, so no socket has ever
    /// opened, yet the network path itself has been fine for a long time. `state` stays stuck at
    /// `.connecting` forever in this situation — `backfillGate` is the separate reading built for
    /// it, and must reach `.stable` with nothing else true at all.
    func testBackfillGateReachesStableWithNoSocketEverOpenedGivenAPathSatisfiedForAWhile() {
        var health = ConnectionHealth()
        _ = health.handle(.pathSatisfied(true), now: start)
        let anHourLater = start.addingTimeInterval(3600)
        XCTAssertEqual(health.state, .connecting, "state itself must stay stuck — this is the bug backfillGate fixes")
        XCTAssertEqual(health.backfillGate(now: anHourLater), .stable)
    }

    func testBackfillGateIsOfflineWhenThePathIsUnsatisfied() {
        let health = ConnectionHealth()
        XCTAssertEqual(health.backfillGate(now: start), .offline)
    }

    /// A close or a mint failure still means "give it a moment" for backfill purposes too — the
    /// same 30s window `state`'s own `unstable` reads, just without requiring a socket.
    func testBackfillGateIsUnstableWithinTheRecentFailureWindowThenStable() {
        var health = ConnectionHealth()
        _ = health.handle(.pathSatisfied(true), now: start)
        _ = health.handle(.mintFailed, now: start)
        let justInsideTheWindow = start.addingTimeInterval(ConnectionHealth.recentFailureWindowSeconds - 1)
        XCTAssertEqual(health.backfillGate(now: justInsideTheWindow), .unstable)
        let justOutsideTheWindow = start.addingTimeInterval(ConnectionHealth.recentFailureWindowSeconds + 1)
        XCTAssertEqual(health.backfillGate(now: justOutsideTheWindow), .stable)
    }

    /// `backfillGate` reads fresh off whatever `now` it is given on every call — no `.tick` event
    /// is needed to let its own window elapse, unlike `state`.
    func testBackfillGateNeedsNoTickToLetItsWindowElapse() {
        var health = ConnectionHealth()
        _ = health.handle(.pathSatisfied(true), now: start)
        _ = health.handle(.socketClosed(reason: nil), now: start)
        let wellPastTheWindow = start.addingTimeInterval(ConnectionHealth.recentFailureWindowSeconds + 1)
        // No `.handle` call at all between `start` and this read — a plain call with a later
        // `now` is enough.
        XCTAssertEqual(health.backfillGate(now: wellPastTheWindow), .stable)
    }
}
