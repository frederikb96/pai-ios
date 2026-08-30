import Foundation
import XCTest

@testable import PAIKit

/// Connects a real `PaiTerminalStreamClient` against a stubbed `URLProtocol` and asserts
/// `onFrame` fires with frames decoded from raw bytes — not from hand-fed lines.
/// `PaiTerminalStreamClientTests` proves the pure pieces (`parseFrame`, `sseDataValue`)
/// individually; this proves they are wired together correctly, exercising the exact `connect()`
/// path production code calls.
///
/// Every test method is `async` even though nothing here is otherwise synchronous-only — see
/// `TranscriptStoreTests`'s doc comment for why a `@MainActor XCTestCase` needs that on Linux.
@MainActor
final class PaiTerminalStreamClientConnectionTests: XCTestCase {

    override func tearDown() {
        PaiStubURLProtocol.reset()
        super.tearDown()
    }

    func testConnectDecodesRawStubbedFramesIntoOnFrameCallbacks() async throws {
        let raw =
            "data: {\"data\":\"hello\",\"live\":true}\r\n\r\ndata: {\"data\":\"world\",\"live\":false}\r\n\r\n"
        PaiStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(raw.utf8))

        let factory = try PaiRequestFactory(baseURL: "https://stub.example.com", tokenProvider: { "jwt" })
        let firstFrame = PaiStreamConnectionSignal()
        let secondFrame = PaiStreamConnectionSignal()
        var frames: [(chunk: String, live: Bool)] = []

        let callbacks = PaiTerminalStreamClient.Callbacks(
            onFrame: { chunk, live in
                frames.append((chunk, live))
                let framesSoFar = frames.count
                Task {
                    if framesSoFar == 1 { await firstFrame.fire() } else { await secondFrame.fire() }
                }
            },
            onConnected: {},
            onDisconnected: {}
        )

        let client = PaiTerminalStreamClient(
            sessionId: "s1", requestFactory: factory, callbacks: callbacks,
            urlSessionConfiguration: PaiStubURLProtocol.makeConfiguration()
        )
        client.connect()

        await firstFrame.wait()
        await secondFrame.wait()
        client.disconnect()

        XCTAssertEqual(frames.map(\.chunk), ["hello", "world"])
        XCTAssertEqual(frames.map(\.live), [true, false])
    }
}
