import XCTest

@testable import PAIKit

final class WakeWordSampleNamingTests: XCTestCase {

    func testSanitizeCollapsesPunctuationAndSpacesToSingleDashes() {
        XCTAssertEqual(WakeWordSampleNaming.sanitize("loud + windy!!"), "loud-windy")
    }

    func testSanitizeLowercasesAndKeepsDigits() {
        XCTAssertEqual(WakeWordSampleNaming.sanitize("AirPods Take 2"), "airpods-take-2")
    }

    func testSanitizeOfAllPunctuationIsEmpty() {
        XCTAssertEqual(WakeWordSampleNaming.sanitize("!!! ??"), "")
    }

    func testFileNameIncludesKindLabelIndexAndTimestamp() {
        let name = WakeWordSampleNaming.fileName(
            kind: .positive, label: "loud windy", index: 3, recordedAtMs: 1_700_000_000_123)
        XCTAssertEqual(name, "positive-loud-windy-3-1700000000123.wav")
    }

    /// An empty (or all-punctuation) label must not leave a stray double dash in the filename —
    /// the shape a naive `"\(kind)-\(label)-\(index)"` string interpolation would produce.
    func testFileNameWithEmptyLabelOmitsTheLabelSegment() {
        let name = WakeWordSampleNaming.fileName(kind: .negative, label: "", index: 1, recordedAtMs: 42)
        XCTAssertEqual(name, "negative-1-42.wav")
    }

    /// The index is what keeps two takes recorded in the same run from ever landing on the same
    /// filename — a boundary a naive implementation keying only on the timestamp could still hit
    /// if two taps land in the same millisecond.
    func testDifferentIndicesProduceDifferentFileNames() {
        let first = WakeWordSampleNaming.fileName(kind: .positive, label: "run", index: 1, recordedAtMs: 1000)
        let second = WakeWordSampleNaming.fileName(kind: .positive, label: "run", index: 2, recordedAtMs: 1000)
        XCTAssertNotEqual(first, second)
    }

    func testStemRoundTripsAgainstFileName() {
        let name = WakeWordSampleNaming.fileName(kind: .positive, label: "quiet", index: 5, recordedAtMs: 999)
        XCTAssertEqual(WakeWordSampleNaming.stem(from: name) + ".wav", name)
    }
}
