import XCTest

@testable import PAIKit

final class WavHeaderReaderTests: XCTestCase {

    func testParsesSampleRateAndDataSizeFromAPcmWavWriterHeader() {
        let header = PcmWavWriter.header(sampleRate: 24000, dataSize: 12345)
        let parsed = WavHeaderReader.parse(header)
        XCTAssertEqual(parsed?.sampleRate, 24000)
        XCTAssertEqual(parsed?.dataSize, 12345)
    }

    /// The exact shape a crash leaves behind: only the placeholder header written, never patched
    /// past zero.
    func testParsesAZeroDataSizeHeaderRatherThanRejectingIt() {
        let header = PcmWavWriter.header(sampleRate: 16000, dataSize: 0)
        let parsed = WavHeaderReader.parse(header)
        XCTAssertEqual(parsed?.sampleRate, 16000)
        XCTAssertEqual(parsed?.dataSize, 0)
    }

    func testRejectsAHeaderShorterThanFortyFourBytes() {
        let truncated = PcmWavWriter.header(sampleRate: 24000, dataSize: 100).prefix(20)
        XCTAssertNil(WavHeaderReader.parse(Data(truncated)))
    }

    func testRejectsBytesThatAreNotAWavHeaderAtAll() {
        XCTAssertNil(WavHeaderReader.parse(Data(repeating: 0, count: 44)))
    }

    /// Reads only the fixed offsets, tolerating anything appended after byte 44 — the shape a
    /// real recording's header is always found in, with sample data trailing it.
    func testIgnoresBytesPastTheHeaderItself() {
        var header = PcmWavWriter.header(sampleRate: 8000, dataSize: 4)
        header.append(contentsOf: [1, 2, 3, 4])
        let parsed = WavHeaderReader.parse(header)
        XCTAssertEqual(parsed?.sampleRate, 8000)
        XCTAssertEqual(parsed?.dataSize, 4)
    }
}
