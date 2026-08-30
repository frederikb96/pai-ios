import PAIKit
import SwiftUI

@main
struct PAIApp: App {

    /// The only way to receive an APNs device token — the callback is delivered to an app
    /// delegate or nowhere, and SwiftUI has no equivalent.
    @UIApplicationDelegateAdaptor(PushRegistrar.self) private var pushRegistrar

    #if DEBUG
        /// Held for the app's lifetime; a listener that goes out of scope stops listening.
        private static let debugBridge = DebugBridge(router: DebugRoutes.make())
    #endif

    init() {
        // Unconditional — a TestFlight build is exactly where this matters, and the debug bridge
        // it feeds `/crash` for is the DEBUG-only half of this facility, not the capture itself.
        CrashReporter.install()
        #if DEBUG
            FixtureBootstrap.installIfRequested()
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

            // What the fixture screenshot workflow asks first: which named screens can it launch
            // straight into. Reads `Route.namedScreens` rather than a list kept here in sync by
            // hand, so a screen becomes photographable the moment its case exists — no second
            // place to remember to update.
            router.register("GET", "/screens") { _ in
                .encoding(["screens": Route.namedScreens])
            }

            // Why a screenshot run is looking at the sign-in screen instead of the app. Every
            // screen renders, every check passes and the size floor is satisfied when the gate
            // never opens — the failure is indistinguishable from success without this.
            router.register("GET", "/fixture") { _ in
                .encoding([
                    "fixtureMode": String(PaiFixtureLaunch.isEnabled()),
                    "requestedRoute": PaiFixtureLaunch.requestedRouteName() ?? "none",
                    "hasToken": String(KeychainTokenStore().read() != nil),
                    "keychainWriteStatus": String(KeychainTokenStore.lastWriteStatus),
                ])
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

            // Answers "does the measured height agree with what the view actually draws" without
            // a screenshot — the property nothing checked before a nested list proved it false.
            // `measuredHeight` goes through the exact composer and cache
            // `TranscriptCollectionViewController` calls; `renderedHeight` hosts the exact view a
            // real cell draws, at the same width, and reads back what it actually laid out to.
            router.register("POST", "/markdown/measure") { request in
                let source = String(decoding: request.body, as: UTF8.self)
                let width = request.query["width"].flatMap(Double.init) ?? 360
                return DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        DebugMarkdownMeasurement.compare(source: source, width: width)
                    }
                }
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

            // Reads the same file `CrashReporter.install()` writes on an uncaught exception — a
            // reason string Apple's own crash report leaves out for this class of crash. `nil`
            // encodes as `null`, not a missing key, so a client always gets a well-formed answer.
            router.register("GET", "/crash") { _ in .encoding(CrashReporter.readLast()) }
            router.register("POST", "/crash/clear") { _ in
                CrashReporter.clearLast()
                return .message("cleared")
            }

            routeNames = router.registeredRoutes
            return router
        }

        private nonisolated(unsafe) static var routeNames: [String] = []

        fileprivate static func kind(of block: MarkdownBlock) -> String {
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

    /// Backs `POST /markdown/measure`. Kept as its own type rather than inline in the route
    /// closure so the two numbers it compares are computed the same way every other caller of
    /// each path computes them — nothing here is a shortcut invented for this endpoint.
    enum DebugMarkdownMeasurement {
        struct Report: Encodable {
            let width: Double
            let blockCount: Int
            let kinds: [String]
            let measuredHeight: Double
            let renderedHeight: Double
            /// `measuredHeight - renderedHeight`. Zero is the only value that means the row this
            /// content sits in is neither too short (content clips or overdraws) nor wastefully
            /// tall — see the `scrolling` skill's central rule.
            let delta: Double
        }

        /// SwiftUI layout and `UIHostingController` are main-thread-only; the debug bridge calls
        /// this from its own listener queue via `DispatchQueue.main.sync`, so by the time this
        /// runs the calling thread already *is* the main thread — `assumeIsolated` documents that
        /// rather than hopping again.
        @MainActor
        static func compare(source: String, width: Double) -> DebugRouter.Response {
            let blocks = MarkdownParser.parse(source)
            let environment = MeasurementEnvironment(
                sizeCategoryToken: UITraitCollection.current.preferredContentSizeCategory.rawValue)
            let metrics = MessageLayoutMetrics(blockSpacing: TranscriptContentMetrics.blockSpacing)

            let measuredHeight = MessageContentLayoutComposer.layout(
                of: blocks, width: width, environment: environment, metrics: metrics,
                measurer: TextKitBlockMeasurer(), cache: BlockHeightCache()
            ).totalHeight

            let hosting = UIHostingController(rootView: MarkdownContentView(blocks: blocks).frame(width: width))
            let renderedHeight = hosting.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height

            return .encoding(
                Report(
                    width: width, blockCount: blocks.count, kinds: blocks.map(DebugRoutes.kind(of:)),
                    measuredHeight: measuredHeight, renderedHeight: Double(renderedHeight),
                    delta: measuredHeight - Double(renderedHeight)))
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
