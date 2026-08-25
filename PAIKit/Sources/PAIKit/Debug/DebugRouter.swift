#if DEBUG

    import Foundation

    /// Request routing for the debug bridge, kept free of any networking so it can be tested
    /// without a socket.
    ///
    /// The bridge exists so an agent can read real application state instead of inferring it from
    /// pixels. A screenshot costs seconds and yields coordinates that break on any layout change;
    /// this costs milliseconds, yields JSON, and reaches state that is never on screen at all.
    public struct DebugRouter: Sendable {

        public struct Request: Sendable, Equatable {
            public let method: String
            public let path: String
            public let query: [String: String]
            public let body: Data

            public init(method: String, path: String, query: [String: String] = [:], body: Data = Data()) {
                self.method = method
                self.path = path
                self.query = query
                self.body = body
            }
        }

        public struct Response: Sendable {
            public let status: Int
            public let json: Data

            public init(status: Int = 200, json: Data) {
                self.status = status
                self.json = json
            }

            /// Encodes any `Encodable` payload, falling back to a describable error rather than
            /// throwing — a debug endpoint that fails silently is worse than one that says so.
            public static func encoding(_ value: some Encodable, status: Int = 200) -> Response {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                if let data = try? encoder.encode(value) {
                    return Response(status: status, json: data)
                }
                return .message("could not encode response", status: 500)
            }

            public static func message(_ text: String, status: Int = 200) -> Response {
                let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
                return Response(status: status, json: Data("{\"message\": \"\(escaped)\"}".utf8))
            }
        }

        public typealias Handler = @Sendable (Request) -> Response

        private var routes: [String: Handler] = [:]

        public init() {}

        /// Routes are keyed `"GET /state"`. Registering the same key twice replaces it, so a
        /// later registration wins rather than silently doing nothing.
        public mutating func register(_ method: String, _ path: String, handler: @escaping Handler) {
            routes["\(method.uppercased()) \(normalized(path))"] = handler
        }

        public var registeredRoutes: [String] {
            routes.keys.sorted()
        }

        public func handle(_ request: Request) -> Response {
            let key = "\(request.method.uppercased()) \(normalized(request.path))"
            guard let handler = routes[key] else {
                return .encoding(
                    ["error": "no route for \(key)", "available": registeredRoutes.joined(separator: ", ")],
                    status: 404
                )
            }
            return handler(request)
        }

        /// A trailing slash is the commonest way a hand-typed `curl` misses a route, and the
        /// difference is never meaningful here.
        private func normalized(_ path: String) -> String {
            var result = path.hasPrefix("/") ? path : "/" + path
            while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
            return result
        }

        // MARK: - Wire format

        /// Parses the head of an HTTP request. Deliberately minimal — this listens on loopback in
        /// debug builds only, and anything more would be a web server nobody asked for.
        ///
        /// Returns nil when the head is incomplete, which is the signal to keep reading rather
        /// than to fail: a request can arrive split across packets.
        public static func parse(_ raw: Data) -> Request? {
            guard let headEnd = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            guard let head = String(data: raw[..<headEnd.lowerBound], encoding: .utf8) else { return nil }

            let lines = head.components(separatedBy: "\r\n")
            let parts = (lines.first ?? "").components(separatedBy: " ")
            guard parts.count >= 2 else { return nil }

            var path = parts[1]
            var query: [String: String] = [:]
            if let mark = path.firstIndex(of: "?") {
                let queryString = String(path[path.index(after: mark)...])
                path = String(path[..<mark])
                for pair in queryString.components(separatedBy: "&") where !pair.isEmpty {
                    let kv = pair.components(separatedBy: "=")
                    let key = kv[0].removingPercentEncoding ?? kv[0]
                    let value = kv.count > 1 ? (kv[1].removingPercentEncoding ?? kv[1]) : ""
                    query[key] = value
                }
            }

            // A body shorter than its declared length means the request is still arriving.
            let body = raw[headEnd.upperBound...]
            if let header = lines.first(where: { $0.lowercased().hasPrefix("content-length:") }),
                let declared = Int(header.components(separatedBy: ":")[1].trimmingCharacters(in: .whitespaces)),
                body.count < declared
            {
                return nil
            }

            return Request(method: parts[0], path: path, query: query, body: Data(body))
        }

        public static func serialize(_ response: Response) -> Data {
            var out = Data(
                """
                HTTP/1.1 \(response.status) \(reason(for: response.status))\r
                Content-Type: application/json\r
                Content-Length: \(response.json.count)\r
                Connection: close\r
                \r\n
                """.utf8)
            out.append(response.json)
            return out
        }

        private static func reason(for status: Int) -> String {
            switch status {
            case 200: "OK"
            case 400: "Bad Request"
            case 404: "Not Found"
            case 500: "Internal Server Error"
            default: "Status"
            }
        }
    }

#endif
