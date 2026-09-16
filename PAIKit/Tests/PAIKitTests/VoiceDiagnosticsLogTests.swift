import XCTest

@testable import PAIKit

final class VoiceDiagnosticsLogTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "VoiceDiagnosticsLogTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testLogThenFlushWritesTheMessageToDisk() {
        let log = VoiceDiagnosticsLog(directory: directory)
        log.log(.info, "mode", "take started")
        log.flush()
        let text = String(decoding: log.exportData(), as: UTF8.self)
        XCTAssertTrue(text.contains("take started"))
        XCTAssertTrue(text.contains("[info]"))
        XCTAssertTrue(text.contains("mode:"))
    }

    /// The whole point of splitting `log` from `flush`: a caller on a thread that must not block
    /// (an audio callback) can call `log` freely and nothing hits disk until something else calls
    /// `flush`.
    func testLogAloneDoesNotTouchDiskUntilFlushed() {
        let log = VoiceDiagnosticsLog(directory: directory)
        log.log(.info, "mode", "not yet flushed")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertTrue(contents.isEmpty, "flush() was never called, so nothing should be on disk yet")
    }

    func testCredentialShapedTextIsRedactedBeforeItReachesDisk() {
        let log = VoiceDiagnosticsLog(directory: directory)
        log.log(.error, "socket.stt", "connect failed: wss://api.elevenlabs.io/v1/x?token=verySecretValue123")
        log.flush()
        let text = String(decoding: log.exportData(), as: UTF8.self)
        XCTAssertFalse(text.contains("verySecretValue123"))
        XCTAssertTrue(text.contains("token=<redacted>"))
    }

    func testTotalSizeBytesEqualsTheExportedByteCount() {
        let log = VoiceDiagnosticsLog(directory: directory)
        log.log(.info, "mode", "one")
        log.log(.warning, "mode", "two")
        XCTAssertEqual(log.totalSizeBytes(), log.exportData().count)
    }

    func testClearRemovesEverythingIncludingWhatWasAlreadyFlushed() {
        let log = VoiceDiagnosticsLog(directory: directory)
        log.log(.info, "mode", "before clear")
        log.flush()
        log.clear()
        XCTAssertEqual(log.exportData().count, 0)
        XCTAssertEqual(log.totalSizeBytes(), 0)
    }

    /// Forces a rotation on every line (the cap is smaller than one formatted line) with room for
    /// exactly one rotated file behind the current one — the oldest entry must fall off the end
    /// while the two most recent survive, in chronological order.
    func testRotationKeepsOnlyTheMostRecentEntriesOnceThePerFileCapIsExceeded() {
        let log = VoiceDiagnosticsLog(
            directory: directory, limits: .init(maxCurrentFileBytes: 30, maxRetainedFiles: 2))
        log.log(.info, "mode", "MARKER-ONE")
        log.log(.info, "mode", "MARKER-TWO")
        log.log(.info, "mode", "MARKER-THREE")
        log.flush()

        let text = String(decoding: log.exportData(), as: UTF8.self)
        XCTAssertFalse(text.contains("MARKER-ONE"), "the oldest entry should have rotated out")
        XCTAssertTrue(text.contains("MARKER-TWO"))
        XCTAssertTrue(text.contains("MARKER-THREE"))
        let twoRange = text.range(of: "MARKER-TWO")
        let threeRange = text.range(of: "MARKER-THREE")
        XCTAssertNotNil(twoRange)
        XCTAssertNotNil(threeRange)
        if let twoRange, let threeRange {
            XCTAssertTrue(twoRange.lowerBound < threeRange.lowerBound, "oldest surviving entry reads first")
        }
    }

    /// With no room for a rotated file at all, each new line past the cap replaces history
    /// entirely rather than accumulating — the edge `maxRetainedFiles == 1` still behaves rather
    /// than crashing on an empty rotation range.
    func testWithNoRetainedRotatedFilesOnlyTheNewestEntrySurvives() {
        let log = VoiceDiagnosticsLog(
            directory: directory, limits: .init(maxCurrentFileBytes: 30, maxRetainedFiles: 1))
        log.log(.info, "mode", "MARKER-OLD")
        log.log(.info, "mode", "MARKER-NEW")
        log.flush()

        let text = String(decoding: log.exportData(), as: UTF8.self)
        XCTAssertFalse(text.contains("MARKER-OLD"))
        XCTAssertTrue(text.contains("MARKER-NEW"))
    }

    func testLoggingWithATypedCategoryUsesItsRawValue() {
        let log = VoiceDiagnosticsLog(directory: directory)
        log.log(.info, .connectionHealth, "stable")
        log.flush()
        let text = String(decoding: log.exportData(), as: UTF8.self)
        XCTAssertTrue(text.contains("connection-health: stable"))
    }
}
