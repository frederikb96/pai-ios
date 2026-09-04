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
            let query =
                request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
            let match = Self.route(method: method, path: path, query: query)

            // Neither streaming client checks the content type — both look only at the status —
            // but sending the honest one costs nothing and stops a future reader concluding the
            // stream fixtures are being served wrong when something else is broken. The attachment
            // endpoint's actual caller (`SessionAttachmentChipView.present(_:)`) doesn't check it
            // either — it decides "is this an image" from the file path's own extension — but a
            // JSON content-type on binary PNG bytes would still mislead the next person to read it.
            let isStream = path.hasSuffix("/stream") || path.hasSuffix("/terminal")
            let isAttachment = path.hasPrefix("/api/session/") && path.hasSuffix("/attachment")
            let contentType = isStream ? "text/event-stream" : (isAttachment ? "image/png" : "application/json")
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://fixture.invalid")!,
                statusCode: match.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": contentType]
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
        /// `URLRequest`. `query` defaults to empty so every existing call site (and every
        /// pre-existing test) keeps working unchanged.
        static func route(method: String, path: String, query: [URLQueryItem] = []) -> Match {
            // These two are handled ahead of the plain table below because they are the only
            // routes whose answer genuinely depends on the query string — every other route
            // answers one fixed body regardless of what was asked for. Intercepted by exact path
            // rather than folded into `sessionScoped`, so the ordinary "any session, any id"
            // matching below is untouched for every route that does not need this.
            if method == "GET", path.hasPrefix("/api/session/") {
                if path.hasSuffix("/messages/find") {
                    return Match(status: 200) { findResponse(query: query) }
                }
                if path.hasSuffix("/messages") {
                    return Match(status: 200) { messagesResponse(query: query) }
                }
            }
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

        /// Picks which `ClaudeAuth` snapshot `/api/auth/claude` answers with — `-PaiFixtureAuthState
        /// signedOut|rejected|loginInProgress`, defaulting to the healthy body so the sign-in
        /// banner stays absent (and every other screenshot unaffected) unless a run asks for it.
        private static func claudeAuthFixtureBody() -> String {
            switch PaiFixtureLaunch.requestedAuthState() {
            case "signedOut": return PaiFixtures.claudeAuthSignedOut
            case "rejected": return PaiFixtures.claudeAuthRejected
            case "loginInProgress": return PaiFixtures.claudeAuthLoginInProgress
            default: return PaiFixtures.claudeAuthHealthy
            }
        }

        /// Matches a request under `/api/notes/{id}/…`, regardless of which id was asked for —
        /// the corpus has one note, and a screenshot run never needs to tell notes apart.
        private static func noteScoped(
            _ method: String, suffix: String, _ json: @escaping @Sendable () -> String
        ) -> FixtureRoute {
            FixtureRoute(
                method: method,
                matches: { $0.hasPrefix("/api/notes/") && $0.hasSuffix(suffix) }
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
            exact("GET", "/api/settings/smtp") { PaiFixtures.smtpSettings },
            exact("GET", "/api/auth/claude") { claudeAuthFixtureBody() },
            exact("GET", "/api/browse") { PaiFixtures.browseResult },
            exact("GET", "/api/favorites") { PaiFixtures.folderFavorites },
            exact("POST", "/api/voice/token") { PaiFixtures.voiceToken },
            // Order matters here too, same reason as the notes routes below: `/summary` would
            // otherwise be read by the generic id lookup as a notification whose id is "summary".
            exact("GET", "/api/notifications/summary") { PaiFixtures.notificationsSummary },
            exact("GET", "/api/notifications") { PaiFixtures.notifications },
            exact("POST", "/api/notifications/read") { PaiFixtures.notificationsMarked },
            FixtureRoute(
                method: "GET",
                matches: { $0.hasPrefix("/api/notifications/") && $0.split(separator: "/").count == 3 }
            ) { PaiFixtures.data(PaiFixtures.notificationDetail) },
            exact("POST", "/api/alerts/clear") { PaiFixtures.alertsCleared },
            // `.../messages` and `.../messages/find` are answered by `route(method:path:query:)`
            // itself, ahead of this table — the only two routes whose body genuinely depends on
            // the query string. No entry for either here.
            // The corpus has one attachment, not one per path — matching `sessionScoped`'s own
            // reasoning above, this answers any `?path=` with the same image. A plain
            // `FixtureRoute` rather than `sessionScoped`/`exact`, since both of those funnel their
            // body through `PaiFixtures.data(_ json: String)`, a UTF-8 string encode that would
            // corrupt binary PNG bytes — this route returns `Data` directly instead.
            FixtureRoute(
                method: "GET",
                matches: { $0.hasPrefix("/api/session/") && $0.hasSuffix("/attachment") }
            ) { PaiFixtures.attachmentImage },
            // The notes half. Order matters here and only here: `/api/notes/containers` and
            // `/api/notes/config` would otherwise be read as a note whose id is "containers" or
            // "config".
            exact("GET", "/api/notes") { PaiFixtures.notesIndex },
            exact("GET", "/api/notes/containers") { PaiFixtures.noteContainers },
            exact("GET", "/api/notes/config") { PaiFixtures.notesConfig },
            noteScoped("GET", suffix: "/attachments") { PaiFixtures.noteAttachments },
            noteScoped("GET", suffix: "/links") { PaiFixtures.noteLinkGraph },
            noteScoped("GET", suffix: "/revisions") { PaiFixtures.noteRevisions },
            FixtureRoute(
                method: "GET",
                matches: { $0.hasPrefix("/api/notes/") && $0.split(separator: "/").count == 3 }
            ) { PaiFixtures.data(PaiFixtures.noteDetail) },
            // The two streams. Without these the terminal photographs blank — its content arrives
            // over the stream and nowhere else — and the transcript's live half never runs at all,
            // so the one screen whose whole design is about streaming would be the one screen
            // fixture mode never exercised.
            // ⚠️ The two stream routes are served but do not reach their clients: both use
            // `URLSession.bytes(for:)`, which does not surface a custom `URLProtocol`'s data.
            // So a fixture screenshot of the terminal shows its "connecting" chrome and no
            // frames, and the transcript's content comes from its REST bootstrap rather than
            // from the live stream. Neither is an app fault, and neither is reproducible against
            // a real backend — but a screenshot of those two proves less than it appears to.
            sessionScoped("GET", suffix: "/stream") { PaiFixtures.sseStream },
            sessionScoped("GET", suffix: "/terminal") { PaiFixtures.terminalStream },
            // `exact` ignores the query string (`URLRequest.url?.path` never includes it), so
            // this answers `?session=` regardless of which conversation uuid was asked for.
            exact("GET", "/api/arc/specs") { PaiFixtures.arcSpecs },
            FixtureRoute(
                method: "GET",
                matches: { $0.hasPrefix("/api/arc/specs/") && $0.hasSuffix("/recover") }
            ) { PaiFixtures.data(PaiFixtures.arcRecover) },
            // `/api/arc/specs/{uuid}` — four path segments, one fewer than the `/recover` route
            // above, which this table checks first, so a recover request is never read as this.
            FixtureRoute(
                method: "GET",
                matches: { $0.hasPrefix("/api/arc/specs/") && $0.split(separator: "/").count == 4 }
            ) { PaiFixtures.data(PaiFixtures.arcSpec) },
        ]
    }

#endif
