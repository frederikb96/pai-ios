import PAIKit
import SwiftUI

@main
struct PAIApp: App {

    #if DEBUG
        /// Held for the app's lifetime; a listener that goes out of scope stops listening.
        private static let debugBridge = DebugBridge(router: DebugRoutes.make())
    #endif

    init() {
        #if DEBUG
            Self.debugBridge.start()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

#if DEBUG

    /// The app's debug endpoints.
    ///
    /// These call the same code the UI calls rather than reimplementing it — an endpoint that
    /// answers from its own shortcut can report health while the screen is broken, which is the
    /// one failure this whole facility exists to rule out.
    ///
    /// Reachable from the build host because a simulator shares the Mac's network stack:
    /// `curl 127.0.0.1:8765/state`.
    enum DebugRoutes {

        static func make() -> DebugRouter {
            var router = DebugRouter()

            router.register("GET", "/health") { _ in
                .encoding([
                    "status": "ok",
                    "bundle": Bundle.main.bundleIdentifier ?? "?",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
                    "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
                ])
            }

            router.register("GET", "/routes") { _ in
                .encoding(["routes": routeNames])
            }

            // Parses through the real parser, so this reports what the renderer would actually be
            // handed — not a description of it.
            router.register("POST", "/markdown") { request in
                let source = String(decoding: request.body, as: UTF8.self)
                let blocks = MarkdownParser.parse(source)
                // Annotated because `encoding` takes `some Encodable`, which gives the literal
                // nothing to infer its element type from.
                let payload: [String: DebugValue] = [
                    "blockCount": .int(blocks.count),
                    "kinds": .strings(blocks.map(kind(of:))),
                    "plainText": .string(blocks.plainText),
                ]
                return .encoding(payload)
            }

            router.register("GET", "/logs") { request in
                let level = request.query["level"].flatMap(DebugLogBuffer.Level.init(rawValue:)) ?? .debug
                let limit = request.query["limit"].flatMap(Int.init) ?? 100
                return .encoding(DebugLogBuffer.shared.snapshot(minimumLevel: level, limit: limit))
            }

            router.register("POST", "/logs/clear") { _ in
                DebugLogBuffer.shared.clear()
                return .message("cleared")
            }

            routeNames = router.registeredRoutes
            return router
        }

        private nonisolated(unsafe) static var routeNames: [String] = []

        private static func kind(of block: MarkdownBlock) -> String {
            switch block {
            case .paragraph: "paragraph"
            case .heading: "heading"
            case .codeBlock: "codeBlock"
            case .blockQuote: "blockQuote"
            case .list: "list"
            case .table: "table"
            case .thematicBreak: "thematicBreak"
            case .htmlBlock: "htmlBlock"
            }
        }
    }

    /// A minimal heterogeneous value, so a debug response can mix a count with a list of strings
    /// without either a dictionary of `Any` (not `Encodable`) or a bespoke struct per endpoint.
    enum DebugValue: Encodable {
        case int(Int)
        case string(String)
        case strings([String])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .int(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .strings(let values): try container.encode(values)
            }
        }
    }

#endif
