import XCTest

@testable import PAIKit

final class TakeAddressingTests: XCTestCase {

    /// 16-bit mono PCM: two bytes per sample, offset past the header. A future change to either
    /// number (a stereo take, a header layout change) must show up here rather than as a
    /// silently-misaligned batch upload.
    func testWavByteRangeConvertsSamplesToBytesPastTheHeader() {
        let range = WavByteRange.forSamples(100..<150, headerByteCount: 44)
        XCTAssertEqual(range.offset, 44 + 100 * 2)
        XCTAssertEqual(range.length, 50 * 2)
    }

    func testWavByteRangeDefaultsToTheRealHeaderSize() {
        let range = WavByteRange.forSamples(0..<10)
        XCTAssertEqual(range.offset, WavHeaderReader.headerByteCount)
    }
}
