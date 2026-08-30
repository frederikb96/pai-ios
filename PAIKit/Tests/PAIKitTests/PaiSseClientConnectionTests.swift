import Foundation
import XCTest

@testable import PAIKit

/// Connects a real `PaiSseClient` against a stubbed `URLProtocol` and asserts its callbacks fire
/// with events decoded from raw bytes — not from hand-fed lines. `PaiSseClientTests` and
/// `PaiSseEventAccumulatorTests` prove the pure pieces individually; this proves they are wired
/// together correctly, exercising the exact `connect()` path production code calls.
///
/// Every test method is `async` even though nothing here is otherwise synchronous-only — see
/// `TranscriptStoreTests`'s doc comment for why a `@MainActor XCTestCase` needs that on Linux.
@MainActor
final class PaiSseClientConnectionTests: XCTestCase {

    override func tearDown() {
        PaiStubURLProtocol.reset()
        super.tearDown()
    }

    func testConnectDecodesRawStubbedBytesIntoInitAndBatchCallbacks() async throws {
        let raw =
            "event: init\r\ndata: {\"entries\":[],\"cursor\":1,\"has_more\":false,\"session_tokens\":null}\r\n\r\n"
            + "event: batch\r\ndata: {\"entries\":[],\"session_tokens\":null}\r\n\r\n"
        PaiStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(raw.utf8))

        let factory = try PaiRequestFactory(baseURL: "https://stub.example.com", tokenProvider: { "jwt" })
        let initSignal = PaiStreamConnectionSignal()
        let batchSignal = PaiStreamConnectionSignal()
        var receivedInit: SseInitEvent?
        var receivedBatch: SseBatchEvent?

        let callbacks = PaiSseClient.Callbacks(
            onInit: { event in
                receivedInit = event
                Task { await initSignal.fire() }
            },
            onBatch: { event in
                receivedBatch = event
                Task { await batchSignal.fire() }
            },
            onStatus: { _ in },
            onActivity: {},
            onConnected: {},
            onDisconnected: {}
        )

        let client = PaiSseClient(
            sessionId: "s1", requestFactory: factory, callbacks: callbacks,
            urlSessionConfiguration: PaiStubURLProtocol.makeConfiguration()
        )
        client.connect()

        await initSignal.wait()
        await batchSignal.wait()
        client.disconnect()

        XCTAssertEqual(receivedInit?.cursor, 1)
        XCTAssertEqual(receivedInit?.hasMore, false)
        XCTAssertEqual(receivedBatch?.entries, [])
    }
}
