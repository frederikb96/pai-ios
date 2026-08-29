#if DEBUG

    import Foundation

    // URLSession and friends live in FoundationNetworking on Linux, where the free CI runner
    // builds this package. On Apple platforms the module does not exist and Foundation already
    // has them.
    #if canImport(FoundationNetworking)
        import FoundationNetworking
    #endif

    /// Answers every request from `PaiFixtures` instead of the network, so the screenshot
    /// workflow — and anything later that drives a state a healthy backend will not produce —
    /// needs no backend at all.
    ///
    /// Registered with `URLProtocol.registerClass(_:)` rather than handed to a custom
    /// `URLSessionConfiguration`: that reaches `URLSession.shared`, which is what `PaiApiClient`,
    /// `PaiSseClient` and `PaiTerminalStreamClient` all default to, so nothing that constructs
    /// them needs to change to be intercepted. `canInit` still gates on `PaiFixtureLaunch`, so a
    /// registered-but-inactive protocol leaves an ordinary debug run talking to the real network.
    public final class PaiFixtureURLProtocol: URLProtocol {

        override public class func canInit(with request: URLRequest) -> Bool {
            PaiFixtureLaunch.isEnabled()
        }

        override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override public func startLoading() {
            let method = request.httpMethod ?? "GET"
            let path = request.url?.path ?? ""
            let match = Self.route(method: method, path: path)

            // Neither streaming client checks the content type — both look only at the status —
            // but sending the honest one costs nothing and stops a future reader concluding the
            // stream fixtures are being served wrong when something else is broken.
            let isStream = path.hasSuffix("/stream") || path.hasSuffix("/terminal")
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://fixture.invalid")!,
                statusCode: match.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": isStream ? "text/event-stream" : "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: match.body())
            client?.urlProtocolDidFinishLoading(self)
        }

        override public func stopLoading() {}

        // MARK: - Route table

        struct Match {
            let status: Int
            let body: () -> Data
        }

        private struct FixtureRoute: Sendable {
            let method: String
            let matches: @Sendable (String) -> Bool
            let body: @Sendable () -> Data
        }

        /// The response for a request the table has no entry for: a well-formed `PaiError`
        /// body — `{"detail": ...}` is the one shape every call site already parses — rather than
        /// an empty or wrongly-typed payload a decoder would choke on. Internal, not private, so
        /// `PaiFixtureURLProtocolTests` can assert on it directly without going through a real
        /// `URLRequest`.
        static func route(method: String, path: String) -> Match {
            guard let fixture = routes.first(where: { $0.method == method && $0.matches(path) }) else {
                let detail = "no fixture route for \(method) \(path)"
                return Match(status: 404) { Data("{\"detail\":\"\(detail)\"}".utf8) }
            }
            return Match(status: 200, body: fixture.body)
        }

        private static func exact(_ method: String, _ path: String, _ json: @escaping @Sendable () -> String)
            -> FixtureRoute
        {
            FixtureRoute(method: method, matches: { $0 == path }) { PaiFixtures.data(json()) }
        }

        /// Matches any `/api/session/{id}/...` request ending in `suffix`, regardless of which id
        /// was asked for — the corpus has one transcript, not one per session, and a screenshot
        /// run never needs to tell sessions apart.
        private static func sessionScoped(
            _ method: String, suffix: String, _ json: @escaping @Sendable () -> String
        ) -> FixtureRoute {
            FixtureRoute(
                method: method,
                matches: { $0.hasPrefix("/api/session/") && $0.hasSuffix(suffix) }
            ) { PaiFixtures.data(json()) }
        }

        /// Covers every `GET` a screen fetches to render itself, plus the one `POST` (minting a
        /// voice token) a screen needs before it can even offer recording. Extend this table
        /// alongside a new store's fetch call — it is the one place a fixture response is wired
        /// to the path that requests it.
        private static let routes: [FixtureRoute] = [
            exact("GET", "/api/health") { PaiFixtures.healthOk },
            exact("GET", "/api/session-types") { PaiFixtures.sessionTypes },
            exact("GET", "/api/me") { PaiFixtures.me },
            exact("GET", "/api/agents") { PaiFixtures.agents },
            exact("GET", "/api/sessions") { PaiFixtures.sessions },
            exact("GET", "/api/sessions/search") { PaiFixtures.sessionSearchResults },
            exact("GET", "/api/drafts") { PaiFixtures.drafts },
            exact("GET", "/api/usage") { PaiFixtures.usage },
            exact("GET", "/api/settings/secrets") { PaiFixtures.secretStatuses },
            exact("GET", "/api/auth/claude") { PaiFixtures.claudeAuthHealthy },
            exact("GET", "/api/browse") { PaiFixtures.browseResult },
            exact("GET", "/api/favorites") { PaiFixtures.folderFavorites },
            exact("POST", "/api/voice/token") { PaiFixtures.voiceToken },
            sessionScoped("GET", suffix: "/messages") { PaiFixtures.transcript },
            // The two streams. Without these the terminal photographs blank — its content arrives
            // over the stream and nowhere else — and the transcript's live half never runs at all,
            // so the one screen whose whole design is about streaming would be the one screen
            // fixture mode never exercised.
            sessionScoped("GET", suffix: "/stream") { PaiFixtures.sseStream },
            sessionScoped("GET", suffix: "/terminal") { PaiFixtures.terminalStream },
        ]
    }

#endif
