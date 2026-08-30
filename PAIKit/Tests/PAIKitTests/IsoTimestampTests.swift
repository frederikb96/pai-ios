import XCTest

@testable import PAIKit

/// Every one of these is a string this backend has actually been observed to send. The failure
/// this guards is silent by construction — a rejected timestamp is a `nil`, and a `nil` reads
/// downstream as "the server omitted it", so the field just stops appearing.
final class IsoTimestampTests: XCTestCase {

    /// The shape `GET /api/usage` returns: six fractional digits and a numeric offset rather than
    /// `Z`. A default `ISO8601DateFormatter` returns `nil` for this.
    func testParsesMicrosecondPrecisionWithANumericOffset() {
        XCTAssertNotNil(IsoTimestamp.date(from: "2026-08-30T22:30:00.506812+00:00"))
    }

    /// The shape the agent produces via `Date.toISOString()`: exactly three digits and a `Z`.
    func testParsesMillisecondPrecisionWithZ() {
        XCTAssertNotNil(IsoTimestamp.date(from: "2026-01-01T00:00:00.000Z"))
    }

    /// No fraction at all — the second formatter's whole reason for existing, since the
    /// fractional one rejects this just as firmly as the plain one rejects the others.
    func testParsesATimestampWithNoFractionAtAll() {
        XCTAssertNotNil(IsoTimestamp.date(from: "2026-08-29T14:00:00Z"))
    }

    /// Trimming must not eat the offset that follows the fraction, and must leave a fraction
    /// already short enough completely alone. Asserted on the exact instant rather than just
    /// non-nil: a trim that swallowed the offset would still parse, as a different time.
    func testTrimmingKeepsTheInstantAndTheOffsetIntact() {
        let trimmed = IsoTimestamp.date(from: "2026-08-30T22:30:00.506812+00:00")
        let short = IsoTimestamp.date(from: "2026-08-30T22:30:00.506+00:00")
        XCTAssertEqual(trimmed, short)
        XCTAssertEqual(IsoTimestamp.trimmingFractionToMilliseconds("2026-08-30T22:30:00.5Z"), "2026-08-30T22:30:00.5Z")
    }

    func testGarbageIsRejectedRatherThanGuessedAt() {
        XCTAssertNil(IsoTimestamp.date(from: "not a timestamp"))
        XCTAssertNil(IsoTimestamp.date(from: ""))
    }
}
