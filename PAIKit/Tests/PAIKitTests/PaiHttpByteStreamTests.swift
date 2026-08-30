import Foundation
import XCTest

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import PAIKit

/// Drives raw SSE bytes — not hand-written lines — through `PaiHttpByteStream` and
/// `LineSplitter`, via the same `URLProtocol` stub `PaiApiClientTests` uses for the REST client.
///
/// This is the test that would have caught the historical bug: `bytes.lines` (`AsyncLineSequence`)
/// silently drops blank lines, so `SseEventAccumulator` never saw its record terminator and no
/// event ever decoded — a bug invisible to `PaiSseEventAccumulatorTests`, which hand-feeds lines
/// with the blank ones already present and so never exercises the line *source* at all.
final class PaiHttpByteStreamTests: XCTestCase {

    override func tearDown() {
        PaiStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeRequest() -> URLRequest {
        URLRequest(url: URL(string: "https://stub.example.com/stream")!)
    }

    // MARK: - Event ordering and status validation

    /// `URLSession` never calls `didReceive data:` before `didReceive response:` — `.connected`
    /// rides that same guarantee. A regression here would let a caller start counting "have I
    /// heard from the server yet" before the response actually arrived.
    func testConnectedArrivesBeforeAnyChunk() async throws {
        PaiStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data("hello".utf8))
        let byteStream = PaiHttpByteStream()

        var events: [PaiHttpByteStream.Event] = []
        for try await event in byteStream.start(
            request: makeRequest(), configuration: PaiStubURLProtocol.makeConfiguration())
        {
            events.append(event)
        }

        XCTAssertEqual(events, [.connected, .chunk(Data("hello".utf8))])
    }

    /// The status check both streaming clients relied on `bytes(for:)`'s response for previously
    /// — a non-2xx must end the stream as an error, never surface the error body as if it were
    /// stream content.
    func testNon2xxStatusEndsTheStreamWithoutDeliveringAnyChunk() async {
        PaiStubURLProtocol.stub = .init(statusCode: 404, headers: [:], body: Data("not found".utf8))
        let byteStream = PaiHttpByteStream()

        var caughtStatus: Int?
        var sawChunk = false
        do {
            for try await event in byteStream.start(
                request: makeRequest(), configuration: PaiStubURLProtocol.makeConfiguration())
            {
                if case .chunk = event { sawChunk = true }
            }
            XCTFail("expected StreamError.unexpectedStatus")
        } catch let PaiHttpByteStream.StreamError.unexpectedStatus(status) {
            caughtStatus = status
        } catch {
            XCTFail("unexpected error type: \(error)")
        }

        XCTAssertEqual(caughtStatus, 404)
        XCTAssertFalse(sawChunk, "a rejected response must never surface its body as stream content")
    }

    // MARK: - Raw bytes end to end — the test that would have caught the historical bug

    /// Real SSE framing (`\r\n\r\n`, matching `sse_starlette`'s default), delivered across three
    /// chunks whose boundaries land in the middle of both a line and a `\r\n` terminator itself —
    /// decoded all the way through `LineSplitter` to `SseEventAccumulator` records.
    func testRawSseBytesAcrossChunkBoundariesDecodeToBothEvents() async throws {
        let raw = "event: init\r\ndata: {\"cursor\":1}\r\n\r\nevent: batch\r\ndata: {\"entries\":[]}\r\n\r\n"
        let bytes = Array(raw.utf8)
        // First cut lands right after the `\r` of "event: init\r\n" — splitting the terminator
        // itself across chunk 1 and chunk 2.
        let cut1 = "event: init\r".utf8.count
        // Second cut lands mid-word inside "data: {\"entries\":[]}".
        let cut2 = cut1 + "\ndata: {\"cursor\":1}\r\n\r\nevent: batch\r\ndata: {\"ent".utf8.count

        PaiStubURLProtocol.stub = .init(
            statusCode: 200,
            headers: [:],
            body: Data(bytes),
            bodyChunks: [
                Data(bytes[0..<cut1]),
                Data(bytes[cut1..<cut2]),
                Data(bytes[cut2...]),
            ]
        )

        let byteStream = PaiHttpByteStream()
        var splitter = LineSplitter()
        var accumulator = SseEventAccumulator()
        var decoded: [(name: String, data: String)] = []

        for try await event in byteStream.start(
            request: makeRequest(), configuration: PaiStubURLProtocol.makeConfiguration())
        {
            guard case .chunk(let data) = event else { continue }
            for line in splitter.ingest(data) {
                if let record = accumulator.ingest(line: line) { decoded.append(record) }
            }
        }

        XCTAssertEqual(decoded.map(\.name), ["init", "batch"])
        XCTAssertEqual(decoded.map(\.data), [#"{"cursor":1}"#, #"{"entries":[]}"#])
    }
}
