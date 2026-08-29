import XCTest

@testable import PAIKit

/// Exercises `SseEventAccumulator` directly — the pure framing half of `PaiSseClient` — without
/// the `URLSession` connection machinery around it. Deliberately not named `PaiSseClientTests`:
/// this file is not excluded on Linux (see `Package.swift`), so it is the part of the SSE stream
/// covered on the free runner.
final class PaiSseEventAccumulatorTests: XCTestCase {

    func testWellFormedRecordProducesNameAndData() {
        var accumulator = SseEventAccumulator()
        XCTAssertNil(accumulator.ingest(line: "event: batch"))
        XCTAssertNil(accumulator.ingest(line: "data: {\"a\":1}"))
        let event = accumulator.ingest(line: "")
        XCTAssertEqual(event?.name, "batch")
        XCTAssertEqual(event?.data, "{\"a\":1}")
    }

    /// Multiple `data:` lines in one record join with `\n` — an SSE record can carry a
    /// multi-line payload this way, and losing the join would silently truncate it.
    func testMultipleDataLinesJoinWithNewline() {
        var accumulator = SseEventAccumulator()
        _ = accumulator.ingest(line: "event: batch")
        _ = accumulator.ingest(line: "data: line1")
        _ = accumulator.ingest(line: "data: line2")
        let event = accumulator.ingest(line: "")
        XCTAssertEqual(event?.data, "line1\nline2")
    }

    /// A blank line with data but no `event:` line is an incomplete record — discarded, not
    /// emitted as an event with an empty name.
    func testBlankLineWithNoEventNameDiscardsTheRecord() {
        var accumulator = SseEventAccumulator()
        _ = accumulator.ingest(line: "data: orphaned")
        XCTAssertNil(accumulator.ingest(line: ""))
    }

    /// The mirror case: an `event:` line with no `data:` line is also discarded, matching the
    /// original inline loop's `guard let name = eventName, !dataLines.isEmpty`.
    func testBlankLineWithNoDataDiscardsTheRecord() {
        var accumulator = SseEventAccumulator()
        _ = accumulator.ingest(line: "event: ping")
        XCTAssertNil(accumulator.ingest(line: ""))
    }

    /// After a completed (or discarded) record, the accumulator must not leak state into the
    /// next one — a stream carries many records back to back.
    func testStateResetsAfterEachRecordRegardlessOfOutcome() {
        var accumulator = SseEventAccumulator()
        _ = accumulator.ingest(line: "event: status")
        _ = accumulator.ingest(line: "data: first")
        _ = accumulator.ingest(line: "")

        // A record with data but no fresh event name must not inherit "status" from before.
        _ = accumulator.ingest(line: "data: second")
        XCTAssertNil(accumulator.ingest(line: ""), "the second record named no event and must be discarded")
    }

    /// A realistic multi-record stream, exercised end to end through the accumulator exactly as
    /// `PaiSseClient` feeds it line by line — including a bare `ping` with no `data:` line at
    /// all, the shape the watchdog keep-alive actually sends, which must be dropped rather than
    /// surfacing as an event with an empty name.
    func testSequenceOfRecordsEachProducesItsOwnEvent() {
        var accumulator = SseEventAccumulator()
        let lines = [
            "event: init", "data: {\"cursor\":1}", "",
            "event: ping", "",
            "event: batch", "data: {\"entries\":[]}", "",
        ]
        var events: [(name: String, data: String)] = []
        for line in lines {
            if let event = accumulator.ingest(line: line) { events.append(event) }
        }
        XCTAssertEqual(events.map(\.name), ["init", "batch"], "a ping with no data line must not emit")
    }

    // MARK: - sseDataValue

    func testSseDataValueStripsExactlyOneLeadingSpace() {
        XCTAssertEqual(SseEventAccumulator.sseDataValue(from: " {\"a\":1}"), "{\"a\":1}")
    }

    func testSseDataValuePreservesInteriorAndTrailingWhitespace() {
        XCTAssertEqual(SseEventAccumulator.sseDataValue(from: "  {\"a\": 1}  "), " {\"a\": 1}  ")
    }

    func testSseDataValueLeavesLineWithoutLeadingSpaceUntouched() {
        XCTAssertEqual(SseEventAccumulator.sseDataValue(from: "no-leading-space"), "no-leading-space")
    }
}
