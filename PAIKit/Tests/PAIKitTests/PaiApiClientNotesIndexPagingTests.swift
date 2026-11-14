import Foundation
import XCTest

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import PAIKit

/// A `URLProtocol` that answers `/api/notes` from the `offset` it was asked for, so a paging
/// walk sees a real sequence of pages rather than the same canned page forever.
///
/// Its own state doubles as the assertion surface: `requestedOffsets` is what proves the walk
/// happened at all, which a test reading only the returned array cannot tell apart from a
/// backend that answered everything in one page.
final class NotesPagingStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _total = 0
    nonisolated(unsafe) private static var _pageSize = 0
    nonisolated(unsafe) private static var _overlap = 0
    nonisolated(unsafe) private static var _requestedOffsets: [Int] = []

    /// `overlap` makes every page after the first start that many rows early, the way a reorder
    /// between two requests repeats the rows at a page boundary.
    static func configure(total: Int, pageSize: Int, overlap: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        _total = total
        _pageSize = pageSize
        _overlap = overlap
        _requestedOffsets = []
    }

    static var requestedOffsets: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return _requestedOffsets
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NotesPagingStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let offset = Int(components?.queryItems?.first { $0.name == "offset" }?.value ?? "0") ?? 0
        let limit = Int(components?.queryItems?.first { $0.name == "limit" }?.value ?? "0") ?? 0

        Self.lock.lock()
        Self._requestedOffsets.append(offset)
        let total = Self._total
        let pageSize = Self._pageSize
        let start = offset > 0 ? max(0, offset - Self._overlap) : 0
        Self.lock.unlock()

        let count = max(0, min(pageSize, min(limit, total - start)))
        let rows = (0..<count).map { index -> String in
            let n = start + index
            return """
                {"id": "n\(n)", "name": "Note \(n)", "summary": null, "tags": [],
                 "favourite": false, "updated_at_ms": \(1_700_000_000_000 - n),
                 "container_id": null, "pending_delete": false}
                """
        }
        let body = Data("{\"notes\": [\(rows.joined(separator: ","))]}".utf8)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// `GET /api/notes` caps a page at 500 rows, and a vault well past that returns a first page
/// that is indistinguishable from the whole index: 200, hundreds of notes, no error anywhere.
/// Everything below the cut then reads in the filter box as "no note matches", which looks like
/// a broken filter rather than a truncated index — which is exactly how it was reported.
final class PaiApiClientNotesIndexPagingTests: XCTestCase {

    private func makeClient() throws -> PaiApiClient {
        let factory = try PaiRequestFactory(
            baseURL: "https://pai.example.com", deviceName: "Test iPhone", tokenProvider: { "jwt" })
        return PaiApiClient(requestFactory: factory, urlSession: NotesPagingStubURLProtocol.makeSession())
    }

    func testFollowsEveryPageOfAVaultLargerThanOnePage() async throws {
        // A literal, not `pageSize * n`: the point is a corpus that outgrew the page, and an
        // expression built from the page size would keep agreeing with any future page size.
        NotesPagingStubURLProtocol.configure(total: 1830, pageSize: 500)
        let notes = try await makeClient().getNotes(limit: 500)

        XCTAssertEqual(notes.count, 1830)
        XCTAssertEqual(NotesPagingStubURLProtocol.requestedOffsets, [0, 500, 1000, 1500])
        // The oldest note is the one that goes missing when only the first page is read, and it
        // is the half nobody checks — the newest rows are present either way.
        XCTAssertEqual(notes.last?.id, "n1829")
    }

    /// The walk has to end on a short page rather than on an empty one, or every load of an
    /// ordinary vault pays for a wasted final request.
    func testStopsOnTheFirstShortPage() async throws {
        NotesPagingStubURLProtocol.configure(total: 120, pageSize: 500)
        let notes = try await makeClient().getNotes(limit: 500)

        XCTAssertEqual(notes.count, 120)
        XCTAssertEqual(NotesPagingStubURLProtocol.requestedOffsets, [0])
    }

    /// An exactly-full last page is the one case where "short page ends the walk" needs a second
    /// request to discover the end — getting this wrong drops nothing, so no other assertion here
    /// would notice it.
    func testAsksOnceMoreWhenTheLastPageIsExactlyFull() async throws {
        NotesPagingStubURLProtocol.configure(total: 200, pageSize: 100)
        let notes = try await makeClient().getNotes(limit: 100)

        XCTAssertEqual(notes.count, 200)
        XCTAssertEqual(NotesPagingStubURLProtocol.requestedOffsets, [0, 100, 200])
    }

    /// Each page is its own request, so a note that moves across a page boundary between two of
    /// them comes back on both. The list keys its rows by id, and one id on two rows is what the
    /// list renders as a duplicate.
    func testAnIdReturnedByTwoPagesIsListedOnce() async throws {
        NotesPagingStubURLProtocol.configure(total: 1200, pageSize: 500, overlap: 3)
        let notes = try await makeClient().getNotes(limit: 500)

        XCTAssertEqual(NotesPagingStubURLProtocol.requestedOffsets, [0, 500, 1000], "the pages did overlap")
        XCTAssertEqual(notes.count, 1200)
        XCTAssertEqual(Set(notes.map(\.id)).count, notes.count)
        // First copy wins: the order is the first page's, then what only the later pages added.
        XCTAssertEqual(notes.prefix(3).map(\.id), ["n0", "n1", "n2"])
        XCTAssertEqual(notes.last?.id, "n1199")
    }
}
