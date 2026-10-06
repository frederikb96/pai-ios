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

    // MARK: - vanishedUploads

    private func upload(_ remoteId: String, at: Date?) -> DraftAttachmentDisplay.StagedUpload {
        .init(id: UUID(), remoteId: remoteId, uploadedAt: at)
    }

    /// Another device's send claims the rows, so the server stops listing them; the survivor is
    /// still listed and must stay.
    func testAnUploadTheServerNoLongerListsIsDropped() {
        let sent = upload("a1", at: Date(timeIntervalSince1970: 100))
        let kept = upload("a2", at: Date(timeIntervalSince1970: 100))
        let gone = DraftAttachmentDisplay.vanishedUploads(
            [sent, kept], serverIds: ["a2"], requestedAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(gone, [sent.id])
    }

    /// A response produced before the upload landed cannot list it; that silence is not a claim.
    func testAnUploadThatLandedAfterTheRequestLeftIsKept() {
        let fresh = upload("a1", at: Date(timeIntervalSince1970: 300))
        let gone = DraftAttachmentDisplay.vanishedUploads(
            [fresh], serverIds: [], requestedAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(gone, [])
    }

    /// One restored from disk has no timestamp and was uploaded in an earlier launch.
    func testAnUploadRestoredFromDiskIsJudgedByTheServer() {
        let old = upload("a1", at: nil)
        let gone = DraftAttachmentDisplay.vanishedUploads(
            [old], serverIds: [], requestedAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(gone, [old.id])
    }
}
