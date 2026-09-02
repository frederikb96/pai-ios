import XCTest

@testable import PAIKit

final class NotificationDeliveryReconciliationTests: XCTestCase {

    func testClearsOnlyIDsConfirmedRead() {
        let ids = NotificationDeliveryReconciliation.idsToClear(
            deliveredIDs: ["a", "b", "c"], readStatus: ["a": true, "b": false, "c": true])

        XCTAssertEqual(Set(ids), ["a", "c"])
    }

    /// An id `readStatus` never answered for — a failed fetch, or one outside the batch asked
    /// about — must not be guessed at either way; leaving its banner up is the safe failure.
    func testLeavesUnconfirmedIDsAlone() {
        let ids = NotificationDeliveryReconciliation.idsToClear(
            deliveredIDs: ["a", "b"], readStatus: ["a": true])

        XCTAssertEqual(ids, ["a"])
    }

    func testEmptyDeliveredListClearsNothing() {
        let ids = NotificationDeliveryReconciliation.idsToClear(
            deliveredIDs: [], readStatus: ["a": true])

        XCTAssertTrue(ids.isEmpty)
    }
}
