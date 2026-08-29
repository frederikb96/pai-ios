import XCTest

@testable import PAIKit

/// A fake clock the test advances by hand — proves the hold window without a real sleep, and
/// lets a test express "one second before it expires" exactly rather than approximately.
private final class FakeWallClock: WallClock, @unchecked Sendable {
    var current: Date
    init(_ date: Date = Date(timeIntervalSince1970: 0)) { current = date }
    func now() -> Date { current }
    func advance(by seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}

/// Every method is `async` even where nothing inside it awaits anything — see
/// `TranscriptStoreTests`'s doc comment for why a `@MainActor` `XCTestCase` needs that on Linux.
@MainActor
final class TranscriptHoldTests: XCTestCase {

    func testHoldIsActiveJustBeforeItsWindowElapses() async {
        let start = Date(timeIntervalSince1970: 0)
        let hold = TranscriptHold(kind: .bottom, now: start)

        XCTAssertTrue(hold.isActive(now: start.addingTimeInterval(TranscriptHold.duration - 0.01)))
    }

    func testHoldIsInactiveOnceItsWindowElapses() async {
        let start = Date(timeIntervalSince1970: 0)
        let hold = TranscriptHold(kind: .bottom, now: start)

        XCTAssertFalse(hold.isActive(now: start.addingTimeInterval(TranscriptHold.duration)))
    }

    /// Extending must restart the full window from the moment it is called, not merely delay the
    /// original deadline — a resize settling in slowly needs every extension to buy a fresh
    /// duration or it lapses mid-settle.
    func testExtendingRestartsTheFullWindowFromNow() async {
        let start = Date(timeIntervalSince1970: 0)
        let hold = TranscriptHold(kind: .restore(messageId: 7), now: start)
        let almostExpired = start.addingTimeInterval(TranscriptHold.duration - 0.01)

        let extended = hold.extended(now: almostExpired)

        XCTAssertTrue(extended.isActive(now: almostExpired.addingTimeInterval(TranscriptHold.duration - 0.01)))
        XCTAssertEqual(extended.kind, .restore(messageId: 7), "extending must not change what is being held")
    }

    func testControllerReleaseEndsAnActiveHoldImmediately() async {
        let clock = FakeWallClock()
        let controller = TranscriptHoldController(clock: clock)

        controller.begin(.bottom)
        XCTAssertTrue(controller.isActive)

        controller.release()
        XCTAssertFalse(
            controller.isActive, "a released hold must not read as active even before its window would have elapsed")
    }

    func testControllerIsActiveBecomesFalseOnceTheClockPassesTheWindowWithoutExtension() async {
        let clock = FakeWallClock()
        let controller = TranscriptHoldController(clock: clock)

        controller.begin(.search(messageId: 3))
        clock.advance(by: TranscriptHold.duration + 0.01)

        XCTAssertFalse(controller.isActive, "a hold nobody extended must not read as active forever")
    }

    func testControllerExtendKeepsItActivePastWhatTheOriginalWindowAloneWouldCover() async {
        let clock = FakeWallClock()
        let controller = TranscriptHoldController(clock: clock)

        controller.begin(.bottom)
        clock.advance(by: TranscriptHold.duration - 0.01)
        controller.extend()
        clock.advance(by: TranscriptHold.duration - 0.01)

        XCTAssertTrue(controller.isActive, "extending should have bought a fresh window from the extension point")
    }
}
