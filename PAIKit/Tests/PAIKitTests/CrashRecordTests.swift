import XCTest

@testable import PAIKit

/// `CrashRecord` is what survives a crash to the next launch — a decode failure here would mean
/// a captured crash reads back as nothing, silently, on the one path that only ever runs once per
/// incident and can never be retried.
final class CrashRecordTests: XCTestCase {

    func testRoundTripsThroughJSONWithAllFieldsPresent() throws {
        let record = CrashRecord(
            name: "NSInternalInconsistencyException",
            reason: "Invalid batch updates",
            callStack: ["0  CoreFoundation  0x0000000180001234", "1  UIKitCore  0x0000000181005678"],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(CrashRecord.self, from: data)
        XCTAssertEqual(decoded, record)
    }

    /// `NSException.reason` is genuinely optional at the API — a crash with no reason string must
    /// still round-trip rather than fail to decode.
    func testRoundTripsWithANilReason() throws {
        let record = CrashRecord(name: "SomeException", reason: nil, callStack: [], capturedAt: Date())
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(CrashRecord.self, from: data)
        XCTAssertNil(decoded.reason)
        XCTAssertEqual(decoded.name, "SomeException")
    }

    /// A file written by a build before `appVersion` existed is still on devices; it must decode.
    func testDecodesARecordWrittenWithoutAppVersion() throws {
        let json = #"{"name":"X","callStack":[],"capturedAt":0}"#
        let decoded = try JSONDecoder().decode(CrashRecord.self, from: Data(json.utf8))
        XCTAssertNil(decoded.appVersion)
    }

    func testIsPresentedOnlyUntilSeen() {
        let record = CrashRecord(name: "X", reason: nil, callStack: [], capturedAt: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(record.isUnseen(lastSeenCapturedAt: nil))
        XCTAssertFalse(record.isUnseen(lastSeenCapturedAt: Date(timeIntervalSince1970: 100)))
        XCTAssertTrue(record.isUnseen(lastSeenCapturedAt: Date(timeIntervalSince1970: 50)))
    }
}
