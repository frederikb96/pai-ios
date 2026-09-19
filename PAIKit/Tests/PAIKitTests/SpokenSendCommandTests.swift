import XCTest

@testable import PAIKit

final class SpokenSendCommandTests: XCTestCase {
    func testStripsThePhraseWhenItClosesTheText() {
        XCTAssertEqual(
            SpokenSendCommand.strip(from: "buy some milk on the way home computer send the message"),
            "buy some milk on the way home")
    }

    func testAcceptsAVerbInflection() {
        XCTAssertEqual(SpokenSendCommand.strip(from: "hello there computer sent the message"), "hello there")
    }

    func testDoesNothingWhenTheTextEndsElsewhere() {
        XCTAssertNil(SpokenSendCommand.strip(from: "computer send the message and then some more"))
    }

    func testDoesNothingWithNoPhraseAtAll() {
        XCTAssertNil(SpokenSendCommand.strip(from: "just an ordinary sentence"))
    }

    func testDoesNothingOnEmptyText() {
        XCTAssertNil(SpokenSendCommand.strip(from: ""))
    }

    func testAPhraseAloneStripsToAnEmptyMessage() {
        XCTAssertEqual(SpokenSendCommand.strip(from: "computer send the message"), "")
    }
}
