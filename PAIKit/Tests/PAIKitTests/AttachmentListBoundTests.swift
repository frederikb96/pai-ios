import XCTest

@testable import PAIKit

final class AttachmentListBoundTests: XCTestCase {

    /// A message that fits draws no extra row; one that does not draws exactly one, however far
    /// past the bound it runs — the figures sit either side of the boundary on purpose.
    func testTheTranscriptColumnGrowsByOneRowOnlyOnceSomethingIsHidden() {
        XCTAssertEqual(AttachmentListBound.transcriptRowCount(total: 0), 0)
        XCTAssertEqual(AttachmentListBound.transcriptRowCount(total: 3), 3)
        XCTAssertEqual(AttachmentListBound.transcriptRowCount(total: 4), 4)
        XCTAssertEqual(AttachmentListBound.transcriptRowCount(total: 100), 4)
    }

    func testHiddenCountIsWhatSitsBehindTheControl() {
        XCTAssertEqual(AttachmentListBound.hiddenCount(total: 100, limit: AttachmentListBound.composerVisible), 95)
        XCTAssertEqual(AttachmentListBound.hiddenCount(total: 5, limit: AttachmentListBound.composerVisible), 0)
        XCTAssertEqual(AttachmentListBound.visibleCount(total: 2, limit: AttachmentListBound.composerVisible), 2)
    }
}
