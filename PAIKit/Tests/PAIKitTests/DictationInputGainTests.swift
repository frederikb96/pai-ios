import XCTest

@testable import PAIKit

final class DictationInputGainTests: XCTestCase {

    func testRaisesSamplesByTheConfiguredGain() {
        let out = DictationInputGain.apply(to: [1000, -1000, 0])
        let expected = (1000 * DictationInputGain.factor).rounded()
        XCTAssertEqual(Double(out[0]), expected)
        XCTAssertEqual(Double(out[1]), -expected)
        XCTAssertEqual(out[2], 0)
        // 8 dB is a factor of about 2.5.
        XCTAssertEqual(DictationInputGain.factor, 2.512, accuracy: 0.001)
    }

    func testSaturatesInsteadOfWrapping() {
        XCTAssertEqual(DictationInputGain.apply(to: [20000, -20000, .max, .min]), [.max, .min, .max, .min])
    }

    func testLevelIsScaledAndCappedAtOne() {
        XCTAssertEqual(DictationInputGain.apply(toLevel: 0.1), 0.1 * DictationInputGain.factor, accuracy: 1e-9)
        XCTAssertEqual(DictationInputGain.apply(toLevel: 0.9), 1)
    }
}
