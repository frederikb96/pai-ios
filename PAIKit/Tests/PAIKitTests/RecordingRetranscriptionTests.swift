import XCTest

@testable import PAIKit

final class RecordingRetranscriptionTests: XCTestCase {

    /// A recording just over two pieces long: every piece but the last is five minutes, each
    /// starts a second before the previous one ended, and the last one ends exactly at the end —
    /// nothing past the audio, nothing before it skipped.
    func testPiecesCoverTheWholeRecordingWithOneSecondOverlaps() {
        let pieces = RecordingRetranscription.pieces(totalSamples: 601 * 100, sampleRate: 100)
        XCTAssertEqual(pieces, [0..<30_000, 29_900..<59_900, 59_800..<60_100])
    }

    func testAShortRecordingIsOnePiece() {
        XCTAssertEqual(RecordingRetranscription.pieces(totalSamples: 4_000, sampleRate: 100), [0..<4_000])
    }

    /// Each piece after the first carries the text so far — bounded — so the backend can strip
    /// the overlap; the client only joins the answers.
    func testEachPieceAfterTheFirstCarriesTheTextSoFar() async throws {
        let calls = CallLog()
        let text = try await RecordingRetranscription.run(
            totalSamples: 601 * 100, sampleRate: 100,
            read: { range in [Int16](repeating: 0, count: range.count) },
            transcribe: { _, previous in
                let index = await calls.record(previous)
                return index == 1 ? String(repeating: "a", count: 250) : "piece\(index)"
            }
        )
        let previous = await calls.previousTexts
        XCTAssertEqual(previous.count, 3)
        XCTAssertNil(previous[0])
        XCTAssertEqual(previous[1], String(repeating: "a", count: 200))
        XCTAssertEqual(previous[2]?.hasSuffix(" piece2"), true)
        XCTAssertEqual(previous[2]?.count, 200)
        XCTAssertEqual(text, String(repeating: "a", count: 250) + " piece2 piece3")
    }
}

private actor CallLog {
    private(set) var previousTexts: [String?] = []

    func record(_ previous: String?) -> Int {
        previousTexts.append(previous)
        return previousTexts.count
    }
}
