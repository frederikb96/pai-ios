import XCTest

@testable import PAIKit

// Every test method here is declared `async`, even though none awaits anything, on purpose: the
// Linux test-discovery shim wraps an `async` `@MainActor` method through `asyncTest(_:)`, which
// erases its actor isolation to the plain `() -> ()` the generated runner's array needs. A
// synchronous `@MainActor` method gets no such wrapper — referenced bare, its isolation survives
// into the array literal's inferred type, and the runner's later force-cast to `() -> ()` crashes
// at launch with `Could not cast value of type ... to ...`, a SIGABRT before a single test runs
// rather than a red test. Caught by actually running the suite: a build alone stays silent.
@MainActor
final class TranscriptJumpRequestsTests: XCTestCase {

    func testRequestIsVisibleToPendingMessageIDForTheSameSession() async {
        let requests = TranscriptJumpRequests()
        requests.request(sessionID: "s1", messageID: 42)

        XCTAssertEqual(requests.pendingMessageID(for: "s1"), 42)
    }

    func testARequestForOneSessionDoesNotAppearUnderAnother() async {
        let requests = TranscriptJumpRequests()
        requests.request(sessionID: "s1", messageID: 42)

        XCTAssertNil(requests.pendingMessageID(for: "s2"))
    }

    func testConsumeReturnsTheValueAndClearsIt() async {
        let requests = TranscriptJumpRequests()
        requests.request(sessionID: "s1", messageID: 42)

        XCTAssertEqual(requests.consume(sessionID: "s1"), 42)
        XCTAssertNil(requests.pendingMessageID(for: "s1"))
        XCTAssertNil(requests.consume(sessionID: "s1"), "a second consume finds nothing left to pop")
    }

    func testALaterRequestReplacesAnUnconsumedEarlierOneForTheSameSession() async {
        let requests = TranscriptJumpRequests()
        requests.request(sessionID: "s1", messageID: 1)
        requests.request(sessionID: "s1", messageID: 2)

        XCTAssertEqual(requests.consume(sessionID: "s1"), 2)
    }
}
