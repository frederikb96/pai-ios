import Foundation
import XCTest

@testable import PAIKit

/// Connects a real `PaiNotificationStreamClient` against a stubbed `URLProtocol` and asserts
/// `onNotification`/`onRead` fire from raw stubbed SSE bytes — not from hand-fed events. Mirrors
/// `PaiTerminalStreamClientConnectionTests`, which proves the same "wired together correctly"
/// question for a sibling streaming client the same way.
@MainActor
final class PaiNotificationStreamClientTests: XCTestCase {

    override func tearDown() {
        PaiStubURLProtocol.reset()
        super.tearDown()
    }

    func testConnectDecodesStubbedNotificationAndReadEventsIntoCallbacks() async throws {
        let notificationJson = """
            {"notification":{"id":"n1","kind":"agent","title":"t","body":"b","created_at":"2026-01-01T00:00:00Z",\
            "read_at":null,"session_id":"s1","session_title":"Session","anchor":null,"alert":null},"unread":3}
            """
        let raw =
            "event: notification\r\ndata: \(notificationJson)\r\n\r\nevent: read\r\ndata: {\"unread\":1}\r\n\r\n"
        PaiStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(raw.utf8))

        let factory = try PaiRequestFactory(baseURL: "https://stub.example.com", tokenProvider: { "jwt" })
        let notificationSignal = PaiStreamConnectionSignal()
        let readSignal = PaiStreamConnectionSignal()
        var notifications: [SseNotificationEvent] = []
        var reads: [SseNotificationReadEvent] = []

        let callbacks = PaiNotificationStreamClient.Callbacks(
            onNotification: { event in
                notifications.append(event)
                Task { await notificationSignal.fire() }
            },
            onRead: { event in
                reads.append(event)
                Task { await readSignal.fire() }
            },
            onActivity: {},
            onConnected: {},
            onDisconnected: {}
        )

        let client = PaiNotificationStreamClient(
            requestFactory: factory, callbacks: callbacks,
            urlSessionConfiguration: PaiStubURLProtocol.makeConfiguration()
        )
        client.connect()

        await notificationSignal.wait()
        await readSignal.wait()
        client.disconnect()

        XCTAssertEqual(notifications.map(\.notification.id), ["n1"])
        XCTAssertEqual(notifications.map(\.unread), [3])
        XCTAssertEqual(reads.map(\.unread), [1])
    }

    /// A `ping` keeps the connection alive but names neither callback — the routing this proves
    /// is that an unrecognised/no-op event name is dropped rather than mis-dispatched to one of
    /// them, which a looser `switch` (falling through to `default` only by luck) could get wrong.
    func testPingEventFiresNeitherCallback() async throws {
        let raw = "event: ping\r\ndata: \r\n\r\nevent: read\r\ndata: {\"unread\":0}\r\n\r\n"
        PaiStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(raw.utf8))

        let factory = try PaiRequestFactory(baseURL: "https://stub.example.com", tokenProvider: { "jwt" })
        let readSignal = PaiStreamConnectionSignal()
        var notifications: [SseNotificationEvent] = []
        var reads: [SseNotificationReadEvent] = []

        let callbacks = PaiNotificationStreamClient.Callbacks(
            onNotification: { event in notifications.append(event) },
            onRead: { event in
                reads.append(event)
                Task { await readSignal.fire() }
            },
            onActivity: {},
            onConnected: {},
            onDisconnected: {}
        )

        let client = PaiNotificationStreamClient(
            requestFactory: factory, callbacks: callbacks,
            urlSessionConfiguration: PaiStubURLProtocol.makeConfiguration()
        )
        client.connect()

        await readSignal.wait()
        client.disconnect()

        XCTAssertTrue(notifications.isEmpty)
        XCTAssertEqual(reads.map(\.unread), [0])
    }
}
