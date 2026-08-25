#if DEBUG

    import XCTest

    @testable import PAIKit

    /// The bridge's value is that an agent can trust what it returns. These cover the ways it
    /// could quietly stop being trustworthy: a request that is still arriving treated as
    /// malformed, a route that silently does not exist, and a body whose declared length lies.
    final class DebugRouterTests: XCTestCase {

        private func raw(_ text: String) -> Data { Data(text.utf8) }

        /// A request split across packets is normal. Parsing an incomplete head as though it
        /// were a whole request is how a hand-rolled listener becomes intermittently flaky —
        /// nil means "keep reading", not "reject".
        func testIncompleteHeadIsNotParsedYet() {
            XCTAssertNil(DebugRouter.parse(raw("GET /state HTTP/1.1\r\nHost: x")))
            XCTAssertNotNil(
                DebugRouter.parse(raw("GET /state HTTP/1.1\r\nHost: x\r\n\r\n")),
                "a complete head failed to parse, so the case above proves nothing"
            )
        }

        /// Same rule for the body: a POST whose Content-Length exceeds what has arrived is still
        /// in flight, and acting on half of it would run a command with truncated input.
        func testBodyShorterThanContentLengthIsNotParsedYet() {
            let head = "POST /act HTTP/1.1\r\nContent-Length: 20\r\n\r\n"
            XCTAssertNil(DebugRouter.parse(raw(head + "half")))

            let complete = DebugRouter.parse(raw(head + String(repeating: "x", count: 20)))
            XCTAssertEqual(complete?.body.count, 20)
        }

        func testQueryIsDecoded() {
            let request = DebugRouter.parse(raw("GET /logs?level=error&q=a%20b HTTP/1.1\r\n\r\n"))
            XCTAssertEqual(request?.path, "/logs")
            XCTAssertEqual(request?.query["level"], "error")
            XCTAssertEqual(request?.query["q"], "a b", "percent-encoding was not decoded")
        }

        /// An unknown route must say so *and* say what does exist. A 404 with no list turns every
        /// typo into a debugging session against the wrong layer.
        func testUnknownRouteNamesTheRoutesThatExist() {
            var router = DebugRouter()
            router.register("GET", "/state") { _ in .message("ok") }

            let response = router.handle(DebugRouter.Request(method: "GET", path: "/nope"))
            XCTAssertEqual(response.status, 404)
            let text = String(decoding: response.json, as: UTF8.self)
            XCTAssertTrue(text.contains("GET /state"), "the 404 did not list the available routes: \(text)")
        }

        /// A trailing slash is the commonest hand-typed curl mistake and never means anything
        /// different here.
        func testTrailingSlashMatchesTheSameRoute() {
            var router = DebugRouter()
            router.register("GET", "/state") { _ in .message("hit") }

            for path in ["/state", "/state/"] {
                let response = router.handle(DebugRouter.Request(method: "GET", path: path))
                XCTAssertEqual(response.status, 200, "\(path) did not match")
            }
        }

        /// Methods must not collide: a GET and a POST on one path are different operations, and
        /// conflating them would let a read trigger a write.
        func testMethodIsPartOfTheRouteIdentity() {
            var router = DebugRouter()
            router.register("GET", "/session") { _ in .message("read") }
            router.register("POST", "/session") { _ in .message("write") }

            let read = String(decoding: router.handle(.init(method: "GET", path: "/session")).json, as: UTF8.self)
            let write = String(decoding: router.handle(.init(method: "POST", path: "/session")).json, as: UTF8.self)
            XCTAssertTrue(read.contains("read"))
            XCTAssertTrue(write.contains("write"))
        }

        /// The response has to be a well-formed HTTP message with a byte count that matches the
        /// body, or `curl` hangs waiting for content that never comes.
        func testSerializedResponseDeclaresItsRealLength() {
            let response = DebugRouter.Response.message("hello")
            let wire = String(decoding: DebugRouter.serialize(response), as: UTF8.self)

            XCTAssertTrue(wire.hasPrefix("HTTP/1.1 200 OK"))
            XCTAssertTrue(wire.contains("Content-Length: \(response.json.count)"))
            let body = wire.components(separatedBy: "\r\n\r\n")[1]
            XCTAssertEqual(body.utf8.count, response.json.count, "declared length does not match the body")
        }

        /// Paths are full of slashes; escaping them would make every path in a debug response
        /// unreadable at exactly the moment someone is reading it.
        func testEncodedResponseLeavesSlashesAlone() {
            let response = DebugRouter.Response.encoding(["path": "/Users/frederik/x"])
            XCTAssertTrue(String(decoding: response.json, as: UTF8.self).contains("/Users/frederik/x"))
        }
    }

    final class DebugLogBufferTests: XCTestCase {

        /// The buffer is bounded so a long debug session cannot leak. Dropping the *newest*
        /// instead of the oldest would be the wrong end and would hide what just happened.
        func testBufferKeepsTheMostRecentEntries() {
            let buffer = DebugLogBuffer(capacity: 3)
            for index in 1...5 {
                buffer.append(.info, "test", "entry-\(index)")
            }

            let messages = buffer.snapshot().map(\.message)
            XCTAssertEqual(messages, ["entry-3", "entry-4", "entry-5"])
        }

        /// Filtering is by severity ordering, not equality — asking for warnings must include
        /// errors, or the level filter hides exactly what it was used to find.
        func testLevelFilterIsAThresholdNotAnExactMatch() {
            let buffer = DebugLogBuffer()
            buffer.append(.debug, "t", "d")
            buffer.append(.info, "t", "i")
            buffer.append(.warning, "t", "w")
            buffer.append(.error, "t", "e")

            XCTAssertEqual(buffer.snapshot(minimumLevel: .warning).map(\.message), ["w", "e"])
            XCTAssertEqual(buffer.snapshot(minimumLevel: .debug).count, 4)
        }
    }

#endif
