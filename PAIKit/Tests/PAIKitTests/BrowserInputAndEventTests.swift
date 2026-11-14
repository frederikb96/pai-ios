import XCTest

@testable import PAIKit

private actor Gate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func open() {
        opened = true
        waiting?.resume()
        waiting = nil
    }
}

private actor Sink {
    private(set) var items: [BrowserInput] = []
    func add(_ input: BrowserInput) { items.append(input) }
}

@MainActor
final class BrowserInputQueueTests: XCTestCase {

    /// While the first request is in flight, later wheel deltas add up and order is kept.
    func testWheelDeltasMergeWhileASendIsInFlightAndOrderIsKept() async throws {
        let gate = Gate()
        let sink = Sink()
        let queue = BrowserInputQueue { input in
            await sink.add(input)
            await gate.wait()
        }
        queue.push(.mouse(action: .down, x: 1, y: 1, button: .left))
        queue.push(.wheel(x: 5, y: 5, dx: 0, dy: 10))
        queue.push(.wheel(x: 5, y: 5, dx: 1, dy: 20))
        queue.push(.mouse(action: .up, x: 1, y: 1, button: .left))
        queue.push(.wheel(x: 5, y: 5, dx: 0, dy: 7))
        await gate.open()
        for _ in 0..<200 where await sink.items.count < 4 { try await Task.sleep(nanoseconds: 10_000_000) }
        let items = await sink.items
        XCTAssertEqual(
            items,
            [
                .mouse(action: .down, x: 1, y: 1, button: .left),
                .wheel(x: 5, y: 5, dx: 1, dy: 30),
                .mouse(action: .up, x: 1, y: 1, button: .left),
                .wheel(x: 5, y: 5, dx: 0, dy: 7),
            ])
    }
}

final class BrowserWireTests: XCTestCase {

    func testAFrameEventDecodesItsJpeg() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let data = #"{"t":"frame","w":1280,"h":720,"jpeg":"\#(jpeg.base64EncodedString())"}"#
        XCTAssertEqual(
            BrowserStreamEvent.parse(name: "frame", data: data), .frame(BrowserFrame(w: 1280, h: 720, jpeg: jpeg)))
    }

    func testAFrameThatDoesNotDecodeIsDroppedNotFatal() {
        XCTAssertNil(BrowserStreamEvent.parse(name: "frame", data: #"{"w":1,"h":1,"jpeg":"!!"}"#))
        XCTAssertNil(BrowserStreamEvent.parse(name: "frame", data: "not json"))
    }

    func testAStateEventNeedsOnlyAName() throws {
        let event = BrowserStreamEvent.parse(
            name: "state",
            data: #"{"t":"state","name":"shop","handoff":{"reason":"captcha","since":"2026-11-08T20:00:00+00:00"}}"#)
        guard case .state(let session)? = event else { return XCTFail("no state") }
        XCTAssertEqual(session.name, "shop")
        XCTAssertEqual(session.handoff?.reason, "captcha")
        XCTAssertEqual(session.displayTitle, "shop")
    }

    func testPingsAndUnknownNamesAreNotEvents() {
        XCTAssertNil(BrowserStreamEvent.parse(name: "ping", data: ""))
        XCTAssertNil(BrowserStreamEvent.parse(name: "message", data: "{}"))
    }

    func testInputEncodesTheBackendsFlatShape() throws {
        let object =
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(BrowserInput.mouse(action: .click, x: 3, y: 4, button: .right)))
            as? [String: Any]
        XCTAssertEqual(object?["t"] as? String, "mouse")
        XCTAssertEqual(object?["action"] as? String, "click")
        XCTAssertEqual(object?["button"] as? String, "right")
        XCTAssertEqual(object?["x"] as? Double, 3)
        let key =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(BrowserInput.key("Enter"))) as? [String: Any]
        XCTAssertEqual(key?["key"] as? String, "Enter")
        XCTAssertNil(key?["action"])
    }

    func testBrowserSessionsAreOrderedHandoffFirstThenNewest() {
        let handoff = BrowserHandoff(reason: "x", since: "")
        let ordered = BrowserSessionsStore.ordered([
            BrowserSession(name: "old", lastUsedAt: "2026-11-01T00:00:00+00:00"),
            BrowserSession(name: "waiting", handoff: handoff, lastUsedAt: "2026-10-01T00:00:00+00:00"),
            BrowserSession(name: "new", lastUsedAt: "2026-11-08T00:00:00+00:00"),
        ])
        XCTAssertEqual(ordered.map(\.name), ["waiting", "new", "old"])
    }
}

final class BrowserLinkTests: XCTestCase {

    private func parse(_ string: String, host: String? = "pai.example.com") -> BrowserLink? {
        BrowserLink.parse(URL(string: string)!, backendHost: host)
    }

    func testASessionLinkOnTheBackendHostOpensTheSession() {
        XCTAssertEqual(parse("https://pai.example.com/apps/browser/order-1"), .session(name: "order-1"))
        XCTAssertEqual(parse("https://pai.example.com/apps/browser"), .list)
    }

    func testALinkToAnotherHostOrSchemeIsNotOurs() {
        XCTAssertNil(parse("https://evil.example.org/apps/browser/order-1"))
        XCTAssertNil(parse("http://pai.example.com/apps/browser/order-1"))
        XCTAssertNil(parse("https://pai.example.com/apps/browser/order-1", host: nil))
    }

    func testANameTheBackendWouldRefuseIsNotALink() {
        XCTAssertNil(parse("https://pai.example.com/apps/browser/-bad"))
        XCTAssertNil(parse("https://pai.example.com/apps/browser/a%2Fb"))
        XCTAssertNil(parse("https://pai.example.com/apps/browser/a/b"))
        XCTAssertNil(parse("https://pai.example.com/apps/notes/abc"))
    }

    func testAUniversalLinkOpensTheSameScreens() {
        XCTAssertEqual(
            DeepLink.from(webURL: URL(string: "https://pai.example.com/apps/browser/shop")!), .browser(name: "shop"))
        XCTAssertEqual(DeepLink.from(webURL: URL(string: "https://pai.example.com/apps/browser")!), .browser(name: nil))
        XCTAssertNil(DeepLink.from(webURL: URL(string: "https://pai.example.com/apps/browser/-bad")!))
        XCTAssertEqual(
            DeepLink.from(webURL: URL(string: "https://pai.example.com/apps/notes/n1")!), .note(id: "n1"))
    }

    func testTheCustomSchemeOpensTheSameScreens() {
        XCTAssertEqual(DeepLink.from(url: URL(string: "pai://browser/shop")!), .browser(name: "shop"))
        XCTAssertEqual(DeepLink.from(url: URL(string: "pai://browser")!), .browser(name: nil))
        XCTAssertEqual(DeepLink.browser(name: "shop").routes, [.browserList, .browser(name: "shop")])
        XCTAssertNil(DeepLink.from(url: URL(string: "pai://browser/-bad")!))
    }
}

private actor RecordingBrowserApi: BrowserApiClient {
    private(set) var inputs: [BrowserInput] = []
    func listBrowserSessions() async throws -> [BrowserSession] { [] }
    func sendBrowserInput(name: String, input: BrowserInput) async throws { inputs.append(input) }
    func handBackBrowserSession(name: String, result: BrowserHandbackResult, note: String?) async throws
        -> BrowserHandbackAnswer
    { throw PaiError.transport("not used") }
}

@MainActor
final class BrowserAddressTests: XCTestCase {
    func testAnAddressIsSentAsAGotoAndBlankInputIsDropped() async throws {
        let api = RecordingBrowserApi()
        let factory = try PaiRequestFactory(
            baseURL: "https://pai.example.com", deviceName: "Test iPhone", tokenProvider: { "jwt" })
        let store = BrowserViewStore(name: "b1", api: api, requestFactory: factory)

        store.goto("   ")
        store.goto("  example.com/path ")

        for _ in 0..<200 where await api.inputs.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let inputs = await api.inputs
        XCTAssertEqual(inputs, [.nav(.goto, url: "example.com/path")])
    }
}
