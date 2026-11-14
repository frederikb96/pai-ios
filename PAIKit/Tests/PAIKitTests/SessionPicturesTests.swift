import XCTest

@testable import PAIKit

final class SessionPicturesTests: XCTestCase {

    private func message(_ id: Int, type: MessageType, content: String) -> Message {
        Message(
            id: id, sessionId: "s1", type: type, subtype: nil, outboxId: nil, timestamp: nil,
            content: content, thinking: nil, toolCalls: nil, toolResult: nil, hookSummary: nil,
            tokens: nil, origin: nil, originMeta: nil, createdAt: nil
        )
    }

    private func attached(_ names: String...) -> String {
        "look at these\n\n" + names.map { ".claude/attachments/u1/\($0)" }.joined(separator: " ")
    }

    func testPicturesComeInTranscriptOrderAcrossUserAttachmentsAndReplyMarkers() {
        let messages = [
            message(1, type: .user, content: attached("a.png", "notes.txt", "b.heic")),
            message(2, type: .assistant, content: "here\npai-file: /tmp/c.png\nand a doc\npai-file: /tmp/d.pdf"),
            message(3, type: .user, content: attached("e.jpg")),
        ]
        XCTAssertEqual(
            SessionPictures.paths(in: messages),
            [
                ".claude/attachments/u1/a.png", ".claude/attachments/u1/b.heic", "/tmp/c.png",
                ".claude/attachments/u1/e.jpg",
            ])
    }

    func testAPathShownTwiceIsListedOnceAtItsFirstPlace() {
        let messages = [
            message(1, type: .assistant, content: "pai-file: /tmp/x.png\npai-file: /tmp/y.png"),
            message(2, type: .assistant, content: "pai-file: /tmp/x.png"),
        ]
        XCTAssertEqual(SessionPictures.paths(in: messages), ["/tmp/x.png", "/tmp/y.png"])
    }

    func testAMarkerInsideACodeFenceIsNotAPicture() {
        let text = "```\npai-file: /tmp/shown-as-code.png\n```"
        XCTAssertEqual(SessionPictures.paths(in: [message(1, type: .assistant, content: text)]), [])
    }

    func testNeighboursRunNearestFirstAwayFromThePicture() {
        let all = ["a", "b", "c", "d"]
        XCTAssertEqual(SessionPictures.neighbours(of: "c", in: all, direction: .previous), ["b", "a"])
        XCTAssertEqual(SessionPictures.neighbours(of: "b", in: all, direction: .next), ["c", "d"])
    }

    func testNeighboursAtTheEndsAndForAnUnknownPathAreEmpty() {
        let all = ["a", "b"]
        XCTAssertEqual(SessionPictures.neighbours(of: "a", in: all, direction: .previous), [])
        XCTAssertEqual(SessionPictures.neighbours(of: "b", in: all, direction: .next), [])
        XCTAssertEqual(SessionPictures.neighbours(of: "zzz", in: all, direction: .next), [])
    }
}
