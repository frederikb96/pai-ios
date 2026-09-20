import XCTest

@testable import PAIKit

private func attachment(id: String, state: String = "stored") -> DraftAttachment {
    DraftAttachment(
        id: id, filename: "\(id).png", path: "/tmp/\(id).png", size: 10,
        contentType: "image/png", state: state, createdAt: "t1")
}

final class DraftAttachmentDisplayTests: XCTestCase {

    func testAFileAnotherDeviceAddedIsShown() {
        let shown = DraftAttachmentDisplay.remoteOnly([attachment(id: "a1")], claimedRemoteIds: [])
        XCTAssertEqual(shown.map(\.id), ["a1"])
    }

    /// The moment a local upload lands, the server starts reporting the same file — drawing both
    /// halves puts one photo in the strip twice, with only one of them carrying a thumbnail.
    func testOurOwnUploadIsNotDrawnTwice() {
        let shown = DraftAttachmentDisplay.remoteOnly(
            [attachment(id: "a1"), attachment(id: "a2")], claimedRemoteIds: ["a1"])
        XCTAssertEqual(shown.map(\.id), ["a2"])
    }

    func testAnUnclaimedRowNeedsAttention() {
        XCTAssertTrue(attachment(id: "a1", state: "unclaimed").needsAttention)
    }

    func testAFailedUploadNeedsAttention() {
        XCTAssertTrue(attachment(id: "a1", state: "failed").needsAttention)
    }

    func testAnOrdinaryStoredRowDoesNot() {
        XCTAssertFalse(attachment(id: "a1", state: "stored").needsAttention)
        XCTAssertFalse(attachment(id: "a1", state: "uploading").needsAttention)
    }

    /// A newer backend inventing a state must render as an ordinary attachment rather than as a
    /// problem — the alarming reading is the one nobody would think to check.
    func testAnUnknownStateIsNotTreatedAsAProblem() {
        XCTAssertFalse(attachment(id: "a1", state: "something-new").needsAttention)
    }
}
