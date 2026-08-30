import XCTest

@testable import PAIKit

/// Exercises `LineSplitter` directly — the pure byte-to-line half of the streaming clients, and
/// the type that replaces `bytes.lines` (`AsyncLineSequence`) specifically because that skips
/// blank lines, the SSE record terminator both clients frame on. See `PaiHttpByteStreamTests` for
/// the raw-bytes-to-decoded-events test that proves the fix all the way through.
final class PaiLineSplitterTests: XCTestCase {

    func testCrlfFramingPreservesBlankLines() {
        var splitter = LineSplitter()
        let raw = "event: init\r\ndata: {\"a\":1}\r\n\r\nevent: batch\r\ndata: {\"b\":2}\r\n\r\n"
        XCTAssertEqual(
            splitter.ingest(Data(raw.utf8)),
            ["event: init", "data: {\"a\":1}", "", "event: batch", "data: {\"b\":2}", ""]
        )
    }

    func testLfOnlyFramingAlsoPreservesBlankLines() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.ingest(Data("a\n\nb\n".utf8)), ["a", "", "b"])
    }

    func testLoneCrIsATerminatorToo() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.ingest(Data("a\rb\r\rc".utf8)), ["a", "b", ""])
        XCTAssertEqual(splitter.finish(), "c")
    }

    /// The network can split a chunk anywhere, including inside a two-byte terminator — a `\r`
    /// landing as the very last byte of a chunk must not be treated as a lone-`\r` terminator
    /// before the next chunk has had a chance to reveal whether a `\n` completes it.
    func testCrlfTerminatorSplitAcrossTwoChunksIsNotDoubleCounted() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.ingest(Data("event: init\r".utf8)), [], "a bare trailing \\r must stay buffered")
        XCTAssertEqual(
            splitter.ingest(Data("\ndata: x\r\n\r\n".utf8)),
            ["event: init", "data: x", ""]
        )
    }

    func testLineSplitMidContentAcrossTwoChunksIsReassembled() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.ingest(Data("event: ini".utf8)), [])
        XCTAssertEqual(splitter.ingest(Data("t\r\n\r\n".utf8)), ["event: init", ""])
    }

    func testMultipleLinesInOneChunkAllComeBack() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.ingest(Data("a\r\nb\r\nc\r\n".utf8)), ["a", "b", "c"])
    }

    func testFinishReturnsNilWhenNothingIsPending() {
        var splitter = LineSplitter()
        _ = splitter.ingest(Data("a\r\n".utf8))
        XCTAssertNil(splitter.finish())
    }

    /// End-of-stream is an implicit terminator, the same way a plain line reader treats EOF —
    /// otherwise a connection that closes mid-line would drop its last line forever.
    func testFinishFlushesATrailingLineWithNoTerminator() {
        var splitter = LineSplitter()
        _ = splitter.ingest(Data("trailing".utf8))
        XCTAssertEqual(splitter.finish(), "trailing")
    }
}
