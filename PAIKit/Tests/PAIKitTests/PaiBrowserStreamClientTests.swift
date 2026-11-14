import Foundation
import XCTest

@testable import PAIKit

/// A real client against a stubbed `URLProtocol`, with the body split across chunk boundaries the
/// way a network splits a large frame.
@MainActor
final class PaiBrowserStreamClientTests: XCTestCase {

    override func tearDown() {
        PaiStubURLProtocol.reset()
        super.tearDown()
    }

    func testEventsSurviveChunkSplitsAndEndIsFinal() async throws {
        let jpeg = Data(repeating: 0xAB, count: 5000)
        let frame = #"{"t":"frame","w":800,"h":600,"jpeg":"\#(jpeg.base64EncodedString())"}"#
        let body = Data(
            ("event: state\r\ndata: {\"t\":\"state\",\"name\":\"shop\"}\r\n\r\n"
                + "event: ping\r\ndata: \r\n\r\n"
                + "event: frame\r\ndata: \(frame)\r\n\r\n"
                + "event: end\r\ndata: {\"t\":\"end\",\"reason\":\"gone\"}\r\n\r\n").utf8)
        let chunks = stride(from: 0, to: body.count, by: 777).map { body.subdata(in: $0..<min($0 + 777, body.count)) }
        PaiStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: body, bodyChunks: chunks)

        let factory = try PaiRequestFactory(
            baseURL: "https://stub.example.com", deviceName: "Test iPhone", tokenProvider: { "jwt" })
        let ended = PaiStreamConnectionSignal()
        var events: [BrowserStreamEvent] = []
        let client = PaiBrowserStreamClient(
            sessionName: "shop", requestFactory: factory,
            callbacks: .init(
                onEvent: { event in
                    events.append(event)
                    if case .end = event { Task { await ended.fire() } }
                },
                onConnected: {}, onDisconnected: {}),
            urlSessionConfiguration: PaiStubURLProtocol.makeConfiguration())
        client.connect()
        await ended.wait()
        client.disconnect()

        XCTAssertEqual(events.count, 3)
        guard events.count == 3, case .state(let state) = events[0], case .frame(let decoded) = events[1] else {
            return XCTFail("unexpected events \(events)")
        }
        XCTAssertEqual(state.name, "shop")
        XCTAssertEqual(decoded.jpeg, jpeg)
        XCTAssertEqual(events[2], .end(reason: "gone"))
        XCTAssertEqual(
            PaiStubURLProtocol.capturedRequest?.url?.path, "/api/browser/sessions/shop/stream")
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer jwt")
    }

    func testARefusedStreamEndsInsteadOfRetrying() async throws {
        PaiStubURLProtocol.stub = .init(statusCode: 403, headers: [:], body: Data())
        let factory = try PaiRequestFactory(
            baseURL: "https://stub.example.com", deviceName: "Test iPhone", tokenProvider: { "jwt" })
        let ended = PaiStreamConnectionSignal()
        var events: [BrowserStreamEvent] = []
        let client = PaiBrowserStreamClient(
            sessionName: "shop", requestFactory: factory,
            callbacks: .init(
                onEvent: { event in
                    events.append(event)
                    Task { await ended.fire() }
                },
                onConnected: {}, onDisconnected: {}),
            urlSessionConfiguration: PaiStubURLProtocol.makeConfiguration())
        client.connect()
        await ended.wait()
        client.disconnect()
        XCTAssertEqual(events, [.end(reason: "Only the owner can open browser sessions")])
    }
}
