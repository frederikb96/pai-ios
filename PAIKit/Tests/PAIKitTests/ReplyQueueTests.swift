import XCTest

@testable import PAIKit

final class ReplyQueueTests: XCTestCase {

    func testEnqueueingWithNoSentencesIsANoOp() {
        var queue = ReplyQueue()
        queue.enqueue(messageId: 1, sentences: [])
        XCTAssertTrue(queue.isEmpty)
    }

    func testFifoOrderingArrivingWhileSpeakingIsAppendedNotInserted() {
        var queue = ReplyQueue()
        queue.enqueue(messageId: 1, sentences: ["first."])
        queue.enqueue(messageId: 2, sentences: ["second."])
        queue.enqueue(messageId: 3, sentences: ["third."])

        XCTAssertEqual(queue.head?.messageId, 1)
        queue.completeHead()
        XCTAssertEqual(queue.head?.messageId, 2)
        queue.completeHead()
        XCTAssertEqual(queue.head?.messageId, 3)
        queue.completeHead()
        XCTAssertTrue(queue.isEmpty)
    }

    // MARK: - Skip drops the head wherever it had gotten to

    func testDropHeadRemovesTheHeadRegardlessOfHowManySentencesWereAlreadySent() {
        var queue = ReplyQueue()
        queue.enqueue(messageId: 1, sentences: ["a.", "b.", "c."])
        queue.enqueue(messageId: 2, sentences: ["d."])
        queue.recordSentencesSent(2)

        let dropped = queue.dropHead()
        XCTAssertEqual(dropped?.messageId, 1)
        XCTAssertEqual(queue.head?.messageId, 2)
    }

    func testDropHeadOnAnEmptyQueueReturnsNilAndDoesNotCrash() {
        var queue = ReplyQueue()
        XCTAssertNil(queue.dropHead())
    }

    // MARK: - Resend bookkeeping: `remaining` after a partial send

    func testRemainingIsEverySentenceBeforeAnySendIsRecorded() {
        var queue = ReplyQueue()
        queue.enqueue(messageId: 1, sentences: ["a.", "b.", "c."])
        XCTAssertEqual(queue.head?.remaining, ["a.", "b.", "c."])
    }

    func testRecordSentencesSentAdvancesRemainingByExactlyThatMany() {
        var queue = ReplyQueue()
        queue.enqueue(messageId: 1, sentences: ["a.", "b.", "c."])
        queue.recordSentencesSent(2)
        XCTAssertEqual(queue.head?.remaining, ["c."])
        XCTAssertFalse(queue.head?.isFullySent ?? true)
    }

    func testRecordSentencesSentClampsAtTheEntrysOwnSentenceCount() {
        var queue = ReplyQueue()
        queue.enqueue(messageId: 1, sentences: ["a.", "b."])
        queue.recordSentencesSent(5)
        XCTAssertEqual(queue.head?.remaining, [])
        XCTAssertTrue(queue.head?.isFullySent ?? false)
    }

    func testRecordSentencesSentOnAnEmptyQueueDoesNotCrash() {
        var queue = ReplyQueue()
        queue.recordSentencesSent()
        XCTAssertTrue(queue.isEmpty)
    }

    /// A dropped head's own progress never leaks onto the next entry — each entry starts at zero
    /// regardless of how far the one before it had gotten.
    func testANewHeadAfterASkipStartsWithNothingSentYet() {
        var queue = ReplyQueue()
        queue.enqueue(messageId: 1, sentences: ["a.", "b."])
        queue.enqueue(messageId: 2, sentences: ["c.", "d."])
        queue.recordSentencesSent(2)
        queue.dropHead()

        XCTAssertEqual(queue.head?.messageId, 2)
        XCTAssertEqual(queue.head?.remaining, ["c.", "d."])
    }

    // MARK: - Resetting the head after a dropped connection

    func testResetHeadProgressMakesTheWholeReplyRemainingAgain() {
        var queue = ReplyQueue()
        queue.enqueue(messageId: 1, sentences: ["a.", "b."])
        queue.recordSentencesSent(2)
        XCTAssertTrue(queue.head?.remaining.isEmpty ?? false, "every sentence already handed to the dead context")

        queue.resetHeadProgress()

        XCTAssertEqual(queue.head?.remaining, ["a.", "b."])
    }

    func testResetHeadProgressOnAnEmptyQueueDoesNotCrash() {
        var queue = ReplyQueue()
        queue.resetHeadProgress()
        XCTAssertTrue(queue.isEmpty)
    }

    func testResetHeadProgressOnlyEverTouchesTheHeadEntry() {
        var queue = ReplyQueue()
        queue.enqueue(messageId: 1, sentences: ["a."])
        queue.enqueue(messageId: 2, sentences: ["b.", "c."])
        queue.recordSentencesSent()

        queue.resetHeadProgress()
        queue.dropHead()

        XCTAssertEqual(
            queue.head?.remaining, ["b.", "c."], "the second entry was never touched by resetting the first")
    }
}
