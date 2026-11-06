import XCTest

@testable import PAIKit

@MainActor
final class SessionAttentionTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    private func makeAttention() -> SessionAttention {
        SessionAttention(now: { [unowned self] in self.clock })
    }

    func testWithNoInputASessionIsHeldNotCleared() async {
        let attention = makeAttention()
        XCTAssertFalse(attention.shouldClearNow("s1"))
    }

    func testInputReleasesTheHeldSessionOnce() async {
        let attention = makeAttention()
        XCTAssertFalse(attention.shouldClearNow("s1"))
        XCTAssertEqual(attention.noteActivity(), "s1")
        XCTAssertNil(attention.noteActivity())
    }

    func testRecentInputMeansEngagedAndClearsAtOnce() async {
        let attention = makeAttention()
        attention.noteActivity()
        clock.addTimeInterval(SessionAttention.engagedWindow - 1)
        XCTAssertTrue(attention.shouldClearNow("s1"))
    }

    func testOldInputIsNotEngagement() async {
        let attention = makeAttention()
        attention.noteActivity()
        clock.addTimeInterval(SessionAttention.engagedWindow + 1)
        XCTAssertFalse(attention.shouldClearNow("s1"))
    }

    func testReturningToTheFrontIsNotActivity() async {
        let attention = makeAttention()
        attention.noteActivity()
        attention.setAppActive(false)
        attention.setAppActive(true)
        XCTAssertFalse(attention.shouldClearNow("s1"))
    }

    func testInputWhileInactiveKeepsTheRequestHeld() async {
        let attention = makeAttention()
        XCTAssertFalse(attention.shouldClearNow("s1"))
        attention.setAppActive(false)
        XCTAssertNil(attention.noteActivity())
        attention.setAppActive(true)
        XCTAssertEqual(attention.noteActivity(), "s1")
    }

    func testClearingNowDropsAHeldRequestForTheSameSession() async {
        let attention = makeAttention()
        XCTAssertFalse(attention.shouldClearNow("s1"))
        attention.noteActivity()
        XCTAssertTrue(attention.shouldClearNow("s1"))
        XCTAssertNil(attention.noteActivity())
    }
}
