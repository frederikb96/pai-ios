import XCTest

@testable import PAIKit

final class LedgerFileTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LedgerFileTests-\(UUID().uuidString)", isDirectory: true
        )
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeLedger(takeId: String = "1700000000000") -> TranscriptLedger {
        TranscriptLedger(
            takeId: takeId, mode: .microphone, sampleRate: 16000, draftKey: "session-1", preText: "",
            segments: [Segment(range: 0..<16000, text: "hello", source: .live)]
        )
    }

    func testWriteThenReadRoundTripsTheLedgerExactly() throws {
        let url = directory.appendingPathComponent("ledger.json")
        let ledger = makeLedger()
        try LedgerFile.write(ledger, to: url)
        XCTAssertEqual(LedgerFile.read(from: url), ledger)
    }

    func testReadIsNilWhenNoFileExistsYet() {
        let url = directory.appendingPathComponent("never-written.json")
        XCTAssertNil(LedgerFile.read(from: url))
    }

    func testASecondWriteReplacesTheFirstRatherThanAppending() throws {
        let url = directory.appendingPathComponent("ledger.json")
        try LedgerFile.write(makeLedger(takeId: "first"), to: url)
        try LedgerFile.write(makeLedger(takeId: "second"), to: url)
        XCTAssertEqual(LedgerFile.read(from: url)?.takeId, "second")
    }

    /// The crash-safety property the atomic write exists for: a write that cannot complete (here,
    /// a destination directory that no longer exists) must leave whatever was already on disk
    /// untouched — never a half-written file a reader would otherwise have to guess about.
    func testAFailedWriteLeavesThePreviouslyWrittenLedgerIntact() throws {
        let url = directory.appendingPathComponent("ledger.json")
        try LedgerFile.write(makeLedger(takeId: "safe"), to: url)

        let goneDirectory = directory.appendingPathComponent("gone")
        let unwritable = goneDirectory.appendingPathComponent("ledger.json")
        XCTAssertThrowsError(try LedgerFile.write(makeLedger(takeId: "lost"), to: unwritable))

        XCTAssertEqual(LedgerFile.read(from: url)?.takeId, "safe")
    }

    /// No temp file from a failed attempt is left behind to be mistaken for a real ledger later.
    func testAFailedWriteDoesNotLeaveATempFileInTheDirectory() throws {
        let goneDirectory = directory.appendingPathComponent("gone")
        let unwritable = goneDirectory.appendingPathComponent("ledger.json")
        XCTAssertThrowsError(try LedgerFile.write(makeLedger(), to: unwritable))

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertTrue(contents.isEmpty)
    }
}
