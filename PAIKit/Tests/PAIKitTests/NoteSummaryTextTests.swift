import XCTest
@testable import PAIKit

final class NoteSummaryTextTests: XCTestCase {

    func testReturnInsertedNewlineBecomesASpace() {
        XCTAssertEqual(flattenNoteSummaryLine("first\nsecond"), "first second")
    }

    func testCarriageReturnLineFeedPairBecomesOneSpace() {
        XCTAssertEqual(flattenNoteSummaryLine("first\r\nsecond"), "first second")
    }

    func testConsecutiveNewlinesEachBecomeTheirOwnSpace() {
        XCTAssertEqual(flattenNoteSummaryLine("first\n\nsecond"), "first  second")
    }

    func testTextWithNoNewlineIsUnchanged() {
        XCTAssertEqual(flattenNoteSummaryLine("a plain sentence"), "a plain sentence")
    }
}
