import XCTest
@testable import PAIKit

final class ModelDisplayTests: XCTestCase {

    func testNilWireIdFormatsToNil() {
        XCTAssertNil(ModelDisplay.label(forWireId: nil))
    }

    func testEmptyWireIdFormatsToNil() {
        XCTAssertNil(ModelDisplay.label(forWireId: ""))
    }

    func testKnownWireIdsFormatToShortLabels() {
        XCTAssertEqual(ModelDisplay.label(forWireId: "claude-opus-4-8"), "Opus 4.8")
        XCTAssertEqual(ModelDisplay.label(forWireId: "claude-sonnet-5"), "Sonnet 5")
        XCTAssertEqual(ModelDisplay.label(forWireId: "claude-haiku-4-5"), "Haiku 4.5")
        XCTAssertEqual(ModelDisplay.label(forWireId: "claude-fable-5-1"), "Fable 5.1")
    }

    /// An id this table predates must still read as something, not blank and not the raw
    /// hyphenated wire string — the badge degrades gracefully rather than disappearing.
    func testUnrecognizedWireIdFallsBackToATitleCasedLabel() {
        XCTAssertEqual(ModelDisplay.label(forWireId: "claude-opus-9-1"), "Opus 9 1")
        XCTAssertEqual(ModelDisplay.label(forWireId: "some-future-model"), "Some Future Model")
    }
}
