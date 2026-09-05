import Foundation

// This file and the Codable models under Models/ mirror pai-cloud's web/src/api/types.ts by
// hand. A route or shape added, removed or renamed there is iOS parity work — see
// https://github.com/frederikb96/pai-cloud/blob/main/docs/IOS_PARITY.md.

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Shapes with no equivalent in types.ts

// `client.ts` defines a couple of union return shapes inline rather than in `types.ts`; they
// live here, next to the calls that produce them, for the same reason.

/// `getMessages`'s `tail`, `beforeId` and `afterId` are one navigation mode each — the backend
/// rejects combining them (`client.ts:64-67`) — so this is an enum rather than three optionals
/// a caller could combine by mistake.
// Deliberately no default `limit` on these cases: Swift enum cases cannot carry default
// argument values the way function parameters can, so `nil` has to be passed explicitly at
// every call site instead.
public enum MessagesPage: Sendable, Equatable {
    case tail(limit: Int?)
    case before(id: Int, limit: Int?)
    case after(id: Int, limit: Int?)
}

public struct PaiFileUpload: Sendable, Equatable {
    public let filename: String
    public let mimeType: String
    public let data: Data

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

public enum PutDraftResult: Sendable, Equatable {
    case saved(Draft)
    case deleted(key: String)
}

extension PutDraftResult: Decodable {
    private enum CodingKeys: String, CodingKey { case key, deleted }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decodeIfPresent(Bool.self, forKey: .deleted) == true {
            self = .deleted(key: try container.decode(String.self, forKey: .key))
        } else {
            self = .saved(try Draft(from: decoder))
        }
    }
}

public struct PaiDraftDeleteResult: Codable, Sendable, Equatable {
    public let key: String
    public let deleted: Bool
}

public struct PaiFavoriteRemovalResult: Codable, Sendable, Equatable {
    public let path: String
    public let removed: Bool
}

public struct PaiSupervisionDetachResult: Codable, Sendable, Equatable {
    public let detached: Bool
}

public struct PaiVmShellHandle: Codable, Sendable, Equatable {
    public let sessionId: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
    }
}

public enum PaiTerminalScrollDirection: String, Sendable, Equatable {
    case up, down, live
}

public struct PaiSecretRemovalResult: Codable, Sendable, Equatable {
    public let name: String
    public let removed: Bool
}

public struct PaiSmtpTestResult: Codable, Sendable, Equatable {
    public let sent: Bool
}

/// `GET /api/arc/specs`'s response envelope — unwrapped by `getArcSpecs` so callers deal in a
/// plain `[ArcSpec]`, matching every other list endpoint in this file.
struct ArcSpecsPage: Codable, Sendable, Equatable {
    let specs: [ArcSpec]
}

/// `client.ts`'s `searchSessions` inlines this union rather than naming it in `types.ts`.
public enum SessionSearchMode: String, Sendable, Equatable {
    case fuzzy, semantic
}

/// Which ElevenLabs endpoint the minted token is for — `client.ts`'s `mintVoiceToken` inlines
/// this union rather than naming it in `types.ts`, so it lives here for the same reason
/// `PaiTerminalScrollDirection` does.
public enum VoiceTokenPurpose: String, Sendable, Equatable {
    case realtime, batch
}

/// Raw bytes plus the server-assigned filename — a download, not a JSON response.
public struct PaiExportResult: Sendable, Equatable {
    public let data: Data
    public let filename: String
}

/// Distinguishes "gone" from "broken" rather than throwing for both, because the UI phrases the
/// two differently (`client.ts:321-341`, `getAttachment`).
public enum PaiAttachmentResult: Sendable {
    case ok(data: Data, contentType: String?)
    case notFound
    case error(PaiError)
}

/// `messages(around:limit:sessionId:)`'s own discriminated result — see that method's doc
/// comment for why a 404 there is a distinct outcome rather than a thrown `PaiError`. Unlike
/// `PaiAttachmentResult`, any OTHER non-2xx status still throws normally (via
/// `sendPassingThrough`'s own `checkStatus` fallback), so there is no third `.error` case here.
public enum MessagesAroundResult: Sendable, Equatable {
    case ok(messages: [Message])
    case notFound
}

// MARK: - PaiApiClient

/// Swift port of `pai-cloud/web/src/api/client.ts`. One `send()` chokepoint mirrors the web
/// client's private `request<T>()`; the difference is the `Authorization` header, which the web
/// has no equivalent of at all — it rides an OAuth2-Proxy cookie — and which `PaiRequestFactory`
/// now owns, so every transport (this client, the transcript stream, the terminal stream)
/// applies it the same way instead of each carrying its own copy.
///
/// A plain `Sendable` struct: no mutable state, so it needs no actor isolation and is safe to
/// call from anywhere, including inside the streaming clients' own request construction.
public struct PaiApiClient: Sendable {
    private let requestFactory: PaiRequestFactory
    private let urlSession: URLSession
    private let onAuthenticationFailure: (@Sendable (PaiError) -> Void)?

    /// `onAuthenticationFailure` is called whenever the server refuses the credential, before the
    /// error is thrown to the caller.
    ///
    /// It exists because the alternative does not work: a first-load path is full of calls whose
    /// failure is genuinely not worth surfacing, so they discard the error — and an expired token
    /// then reads as an app with nothing in it and no way back. Noticing here means no caller has
    /// to remember, and a caller that swallows its error still cannot swallow this.
    public init(
        requestFactory: PaiRequestFactory,
        urlSession: URLSession = .shared,
        onAuthenticationFailure: (@Sendable (PaiError) -> Void)? = nil
    ) {
        self.requestFactory = requestFactory
        self.urlSession = urlSession
        self.onAuthenticationFailure = onAuthenticationFailure
    }

    // MARK: Core request helpers

    func send<T: Decodable>(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = "application/json"
    ) async throws -> T {
        let (data, _) = try await sendRaw(
            path: path, method: method, query: query, body: body, contentType: contentType
        )
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PaiError.decoding("\(error)")
        }
    }

    /// For endpoints whose response body the app never reads (e.g. `sendTerminalInput`) — the
    /// status check still runs, the decode does not.
    func sendDiscardingResponse(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = "application/json"
    ) async throws {
        _ = try await sendRaw(path: path, method: method, query: query, body: body, contentType: contentType)
    }

    /// Send a request, handing back the raw body for the statuses in `passthrough` rather than
    /// throwing on them.
    ///
    /// Exists for the one shape `PaiError` deliberately cannot carry: a non-2xx answer whose body
    /// is structured data the caller must act on, not a message to show. A note save answering
    /// 409 with the server's own version of the note is that — the reader has to be shown both
    /// sides, so losing the body would leave "discard your edits" as the only recovery.
    /// Everything else still goes through `checkStatus`, so a passthrough caller cannot
    /// accidentally swallow an auth failure.
    func sendPassingThrough(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = "application/json",
        passthrough: Set<Int>
    ) async throws -> (statusCode: Int, body: Data) {
        let request = try requestFactory.makeRequest(
            path: path, method: method, query: query, body: body, contentType: contentType
        )
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PaiError.transport("Response was not HTTP")
        }
        guard passthrough.contains(http.statusCode) else {
            try checkStatus(response: response, data: data)
            return (http.statusCode, data)
        }
        return (http.statusCode, data)
    }

    private func sendRaw(
        path: String,
        method: String,
        query: [URLQueryItem],
        body: Data?,
        contentType: String?
    ) async throws -> (Data, URLResponse) {
        let request = try requestFactory.makeRequest(
            path: path, method: method, query: query, body: body, contentType: contentType
        )
        let (data, response) = try await urlSession.data(for: request)
        try checkStatus(response: response, data: data)
        return (data, response)
    }

    private func checkStatus(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PaiError.transport("Response was not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            let error = PaiError.from(statusCode: http.statusCode, body: data)
            if error.isAuthenticationFailure { onAuthenticationFailure?(error) }
            throw error
        }
    }

    private static func jsonBody(_ value: some Encodable) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            // An `Encodable` request body failing to encode means a bug in this file, not
            // something the caller can recover from — reusing `.decoding` here keeps `PaiError`
            // to the four cases the web's error contract actually needs, one of them repurposed
            // for "this file has a bug" rather than adding a case solely for that.
            throw PaiError.decoding("\(error)")
        }
    }

    // MARK: Health & session types

    public func getHealth() async throws -> HealthResponse {
        try await send(path: "/api/health")
    }

    public func getSessionTypes() async throws -> [SessionType] {
        try await send(path: "/api/session-types")
    }

    // MARK: Sessions

    /// `since` and `cursor` are two different ways to page this endpoint, never combined:
    /// `since` is the incremental-sync mode (ascending by `updatedAt`, for the poll that keeps
    /// the list current — `agent`/`kind`/`parent`/`q` are ignored there, since it deliberately
    /// answers "what changed" across every machine); `cursor` walks newest-first through the
    /// whole table (descending by `lastActivityAt`), honouring every filter, for loading older
    /// rows the current page didn't include. See `docs/ARCHITECTURE.md`.
    ///
    /// Bypasses `send()`: the next page's cursor comes back as the `X-Next-Cursor` response
    /// header, not a body field — opaque, so callers pass it straight back rather than deriving
    /// one from a row.
    public func getSessions(
        since: String? = nil,
        limit: Int? = nil,
        cursor: String? = nil,
        agent: String? = nil,
        kind: SessionKind? = nil,
        parent: String? = nil,
        q: String? = nil
    ) async throws -> SessionsPage {
        var query: [URLQueryItem] = []
        if let since { query.append(URLQueryItem(name: "since", value: since)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let agent { query.append(URLQueryItem(name: "agent", value: agent)) }
        if let kind {
            let raw: String
            switch kind {
            case .conversation: raw = "conversation"
            case .subagent: raw = "subagent"
            case let .unrecognized(value): raw = value
            }
            query.append(URLQueryItem(name: "kind", value: raw))
        }
        if let parent { query.append(URLQueryItem(name: "parent", value: parent)) }
        if let q { query.append(URLQueryItem(name: "q", value: q)) }

        let request = try requestFactory.makeRequest(path: "/api/sessions", query: query)
        let (data, response) = try await urlSession.data(for: request)
        try checkStatus(response: response, data: data)
        let sessions: [Session]
        do {
            sessions = try JSONDecoder().decode([Session].self, from: data)
        } catch {
            throw PaiError.decoding("\(error)")
        }
        let nextCursor = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Next-Cursor")
        return SessionsPage(sessions: sessions, nextCursor: nextCursor)
    }

    /// `GET /api/sessions/search` — the fuzzy/semantic matcher `csm` reads through too. An
    /// invalid `mode` or an unknown `agent` both 400.
    public func searchSessions(
        q: String,
        mode: SessionSearchMode? = nil,
        agent: String? = nil,
        limit: Int? = nil
    ) async throws -> [SessionSearchResult] {
        var query = [URLQueryItem(name: "q", value: q)]
        if let mode { query.append(URLQueryItem(name: "mode", value: mode.rawValue)) }
        if let agent { query.append(URLQueryItem(name: "agent", value: agent)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await send(path: "/api/sessions/search", query: query)
    }

    public func getMachines() async throws -> [Machine] {
        try await send(path: "/api/agents")
    }

    /// Every value this endpoint answers with — asserted rather than trusted, since this app's
    /// reverse proxy serves the SPA's `index.html` for any unmatched path on the web, and a
    /// route not yet deployed would otherwise decode a status this client cannot recognise
    /// instead of surfacing that as an error.
    private static let recognizedResumeStatuses: [ResumeResponse.Status] = [.resumed, .alreadyRunning, .refused]

    /// Turn a session PAI is not driving into an ordinary managed one — the "resume here" action
    /// on a grey session. Runs the same launch path as any other resume; the only thing new is
    /// that PAI did not start this conversation in the first place. Refused for a subagent,
    /// which has no conversation uuid of its own.
    public func resumeSession(sessionId: String) async throws -> ResumeResponse {
        let result: ResumeResponse = try await send(
            path: "/api/session/\(sessionId)/resume", method: "POST", body: nil, contentType: nil
        )
        guard Self.recognizedResumeStatuses.contains(result.status) else {
            throw PaiError.decoding("Resume did not answer with a recognised status")
        }
        return result
    }

    public func getMessages(sessionId: String, page: MessagesPage) async throws -> [Message] {
        var query: [URLQueryItem] = []
        switch page {
        case let .tail(limit):
            query.append(URLQueryItem(name: "tail", value: "true"))
            if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        case let .before(id, limit):
            query.append(URLQueryItem(name: "before_id", value: String(id)))
            if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        case let .after(id, limit):
            query.append(URLQueryItem(name: "after_id", value: String(id)))
            if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        }
        return try await send(path: "/api/session/\(sessionId)/messages", query: query)
    }

    /// A page straddling `aroundId` — `ceil(limit/2)` at-or-before it, `floor(limit/2)` after.
    /// Its own method rather than a fourth `MessagesPage` case: unlike the other three, this one
    /// can legitimately 404 when `aroundId` names no message in this session, and `locate` has to
    /// tell that apart from any other failure — a deep link's 404 means "not ingested yet, keep
    /// retrying", a server-derived hit's means "the row is gone, drop it". Same
    /// discriminated-result shape `getAttachment` already uses for the same reason.
    public func messages(around aroundId: Int, limit: Int? = nil, sessionId: String) async throws
        -> MessagesAroundResult
    {
        var query: [URLQueryItem] = [URLQueryItem(name: "around_id", value: String(aroundId))]
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        let (statusCode, data) = try await sendPassingThrough(
            path: "/api/session/\(sessionId)/messages", method: "GET", query: query, body: nil,
            contentType: nil, passthrough: [404]
        )
        if statusCode == 404 { return .notFound }
        do {
            return .ok(messages: try JSONDecoder().decode([Message].self, from: data))
        } catch {
            throw PaiError.decoding("\(error)")
        }
    }

    /// Ids of every message matching a text or kind predicate — server recall, client precision
    /// (search-virtualization design, decision 1). Exactly one of `q`/`kind`; `afterId` is the
    /// live-tail catch-up call, scoping `total` to ids past the snapshot a session's search
    /// already has.
    public func findMessages(
        sessionId: String, q: String? = nil, kind: String? = nil, afterId: Int? = nil, limit: Int? = nil
    ) async throws -> MessageFindResult {
        var query: [URLQueryItem] = []
        if let q { query.append(URLQueryItem(name: "q", value: q)) }
        if let kind { query.append(URLQueryItem(name: "kind", value: kind)) }
        if let afterId { query.append(URLQueryItem(name: "after_id", value: String(afterId))) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await send(path: "/api/session/\(sessionId)/messages/find", query: query)
    }

    /// Send a message. Omitting `sessionId` **creates** the session — one path serves both the
    /// New Session screen and an existing chat (`client.ts:81-104`).
    public func postMessage(
        sessionId: String? = nil,
        message: String,
        files: [PaiFileUpload] = [],
        sessionType: String? = nil,
        workingDir: String? = nil,
        agent: String? = nil,
        model: String? = nil
    ) async throws -> PostMessageResponse {
        let boundary = "PAIKit-\(UUID().uuidString)"
        var body = Data()
        Self.appendFormField(&body, boundary: boundary, name: "message", value: message)
        for file in files {
            Self.appendFormFile(&body, boundary: boundary, name: "files", file: file)
        }
        if let sessionId { Self.appendFormField(&body, boundary: boundary, name: "session_id", value: sessionId) }
        if let sessionType {
            Self.appendFormField(&body, boundary: boundary, name: "session_type", value: sessionType)
        }
        if let workingDir { Self.appendFormField(&body, boundary: boundary, name: "working_dir", value: workingDir) }
        // Which machine a brand new session launches on. Ignored server-side once `sessionId`
        // names an existing one.
        if let agent { Self.appendFormField(&body, boundary: boundary, name: "agent", value: agent) }
        // Fixed at creation — ignored server-side once `sessionId` names an existing one.
        if let model { Self.appendFormField(&body, boundary: boundary, name: "model", value: model) }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        return try await send(
            path: "/api/messages",
            method: "POST",
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
    }

    private static func appendFormField(_ body: inout Data, boundary: String, name: String, value: String) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append(value.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
    }

    private static func appendFormFile(_ body: inout Data, boundary: String, name: String, file: PaiFileUpload) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        let filename = Self.escapeContentDispositionValue(file.filename)
        body.append(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: \(file.mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(file.data)
        body.append("\r\n".data(using: .utf8)!)
    }

    /// A filename Freddy picked (an attachment from the camera roll, say) can contain `"`, which
    /// would otherwise close the quoted `filename` parameter early and let the rest of the name
    /// spill into the header as unintended `Content-Disposition` parameters.
    private static func escapeContentDispositionValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    public func cancelSession(sessionId: String) async throws -> CancelResponse {
        try await send(path: "/api/session/\(sessionId)/cancel", method: "POST", body: nil, contentType: nil)
    }

    public func closeSession(sessionId: String) async throws -> CloseResponse {
        try await send(path: "/api/session/\(sessionId)/close", method: "POST", body: nil, contentType: nil)
    }

    public func deleteSession(sessionId: String) async throws -> DeleteResponse {
        try await send(path: "/api/session/\(sessionId)", method: "DELETE", body: nil, contentType: nil)
    }

    public func renameSession(sessionId: String, title: String) async throws -> Session {
        struct Body: Encodable { let title: String }
        return try await send(
            path: "/api/session/\(sessionId)",
            method: "PATCH",
            body: try Self.jsonBody(Body(title: title))
        )
    }

    public func setTitleLocked(sessionId: String, locked: Bool) async throws -> Session {
        struct Body: Encodable {
            let titleLocked: Bool
            enum CodingKeys: String, CodingKey { case titleLocked = "title_locked" }
        }
        return try await send(
            path: "/api/session/\(sessionId)",
            method: "PATCH",
            body: try Self.jsonBody(Body(titleLocked: locked))
        )
    }

    /// How long the session may sit idle before it is closed: `nil` to follow the deployment's
    /// default, `0` to keep it up indefinitely, or minutes.
    public func setIdleTimeout(sessionId: String, minutes: Int?) async throws -> Session {
        struct Body: Encodable {
            let idleTimeoutMinutes: Int?
            enum CodingKeys: String, CodingKey { case idleTimeoutMinutes = "idle_timeout_minutes" }
            // `nil` here means "reset to the deployment default", a real value to send — not
            // "leave this field alone" the way an omitted PATCH key normally would. Swift's
            // synthesized `Encodable` uses `encodeIfPresent` for an `Optional` property and
            // would drop the key entirely on `nil`, silently turning "reset the timeout" into a
            // no-op PATCH body (`{}`). `encode(_:forKey:)` instead writes `null`.
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(idleTimeoutMinutes, forKey: .idleTimeoutMinutes)
            }
        }
        return try await send(
            path: "/api/session/\(sessionId)",
            method: "PATCH",
            body: try Self.jsonBody(Body(idleTimeoutMinutes: minutes))
        )
    }

    /// Persists where Freddy stopped reading this session's transcript — debounced client-side,
    /// see `TranscriptAnchor.readPositionPayload(for:)`. `messageId`/`offsetPx` are `nil`
    /// together when `atBottom` is true: the reader is caught up, nothing to pin a message at.
    @discardableResult
    public func putReadPosition(
        sessionId: String, messageId: Int?, offsetPx: Int?, atBottom: Bool
    ) async throws -> ReadPositionAck {
        struct Body: Encodable {
            let messageId: Int?
            let offsetPx: Int?
            let atBottom: Bool
            enum CodingKeys: String, CodingKey {
                case messageId = "message_id"
                case offsetPx = "offset_px"
                case atBottom = "at_bottom"
            }
            // Matches `setIdleTimeout`'s own `Body`: `nil` is a real value the server distinguishes
            // from an omitted key, so the synthesized `encodeIfPresent` for an `Optional` property
            // would silently drop it instead of sending `null`.
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(messageId, forKey: .messageId)
                try container.encode(offsetPx, forKey: .offsetPx)
                try container.encode(atBottom, forKey: .atBottom)
            }
        }
        return try await send(
            path: "/api/session/\(sessionId)/read-position",
            method: "PUT",
            body: try Self.jsonBody(Body(messageId: messageId, offsetPx: offsetPx, atBottom: atBottom))
        )
    }

    // MARK: Drafts

    public func getDrafts() async throws -> [Draft] {
        try await send(path: "/api/drafts")
    }

    public func putDraft(
        key: String,
        text: String,
        sessionType: String? = nil,
        workingDir: String? = nil,
        model: String? = nil
    ) async throws -> PutDraftResult {
        struct Body: Encodable {
            let text: String
            let sessionType: String?
            let workingDir: String?
            let model: String?
            enum CodingKeys: String, CodingKey {
                case text
                case sessionType = "session_type"
                case workingDir = "working_dir"
                case model
            }
        }
        return try await send(
            path: "/api/drafts/\(Self.encodeDraftKey(key))",
            method: "PUT",
            body: try Self.jsonBody(Body(text: text, sessionType: sessionType, workingDir: workingDir, model: model))
        )
    }

    public func deleteDraft(key: String) async throws -> PaiDraftDeleteResult {
        try await send(
            path: "/api/drafts/\(Self.encodeDraftKey(key))",
            method: "DELETE",
            body: nil,
            contentType: nil
        )
    }

    /// `.urlPathAllowed` treats `/` as a legal *path* character (correct for a whole path, wrong
    /// for a single path *segment*, where a literal `/` in a key must not be read as a segment
    /// separator) — matches `client.ts`'s `encodeURIComponent(key)`, which escapes `/` too. Relies
    /// on `PaiRequestFactory` assembling the request path with `percentEncodedPath` rather than
    /// `appendingPathComponent`, which would otherwise re-encode the `%2F` this produces.
    private static let draftKeyAllowedCharacters =
        CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))

    private static func encodeDraftKey(_ key: String) -> String {
        key.addingPercentEncoding(withAllowedCharacters: draftKeyAllowedCharacters) ?? key
    }

    // MARK: Plan usage

    public func getUsage() async throws -> Usage {
        try await send(path: "/api/usage")
    }

    // MARK: ARC

    /// The specs bound to one conversation — `session` is a conversation uuid
    /// (`Session.claudeSessionId`), never PAI's own session id. Empty when the conversation is
    /// not running under any spec, which is the ordinary case for most sessions.
    public func getArcSpecs(session: String) async throws -> [ArcSpec] {
        let page: ArcSpecsPage = try await send(
            path: "/api/arc/specs", query: [URLQueryItem(name: "session", value: session)])
        return page.specs
    }

    /// Every ARC spec, most recently updated first — never scoped to a conversation, unlike
    /// `getArcSpecs(session:)` above. `query` is a substring over name or uuid; `nil` or empty
    /// asks for everything. Paged rather than fetched whole: `GET /api/arc/specs` defaults to 20
    /// and caps at 100 per page server-side, so a caller that ignored that would silently read
    /// only the first page as if it were the entire list.
    public func listArcSpecs(query: String?, limit: Int, offset: Int) async throws -> [ArcSpec] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "query", value: query)) }
        let page: ArcSpecsPage = try await send(path: "/api/arc/specs", query: items)
        return page.specs
    }

    /// Everything needed to draw a spec's whole timeline in one call — see
    /// `ArcRecoverPayload`'s doc comment.
    public func getArcRecover(specUuid: String) async throws -> ArcRecoverPayload {
        try await send(path: "/api/arc/specs/\(specUuid)/recover")
    }

    /// One spec's own record — fetched alongside `getArcRecover` for its `sessions` list, the
    /// conversation uuids a block card's badge tap searches for a bound session to look up
    /// subagents against (`ArcSubagentLookup.resolveBoundSessionId`). `recover` carries no
    /// session binding of its own.
    public func getArcSpec(uuid: String) async throws -> ArcSpec {
        try await send(path: "/api/arc/specs/\(uuid)")
    }

    /// A report a row or a block leader's `r` field names — full content included, so the report
    /// screen needs nothing else about the spec to have loaded first.
    public func getArcReport(uuid: String) async throws -> ArcReport {
        try await send(path: "/api/arc/reports/\(uuid)")
    }

    // MARK: Scheduler

    public func listSchedulerTasks(limit: Int? = nil, offset: Int? = nil) async throws -> SchedulerTaskListResponse {
        var query: [URLQueryItem] = []
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let offset { query.append(URLQueryItem(name: "offset", value: String(offset))) }
        return try await send(path: "/api/scheduler/tasks", query: query)
    }

    public func getSchedulerTask(taskId: String) async throws -> ScheduledTaskDetail {
        try await send(path: "/api/scheduler/tasks/\(taskId)")
    }

    public func createSchedulerTask(fields: TaskWriteFields) async throws -> ScheduledTaskDetail {
        try await send(path: "/api/scheduler/tasks", method: "POST", body: try Self.jsonBody(fields))
    }

    public func updateSchedulerTask(taskId: String, fields: TaskWriteFields) async throws -> ScheduledTaskDetail {
        try await send(path: "/api/scheduler/tasks/\(taskId)", method: "PATCH", body: try Self.jsonBody(fields))
    }

    public func deleteSchedulerTask(taskId: String) async throws {
        try await sendDiscardingResponse(path: "/api/scheduler/tasks/\(taskId)", method: "DELETE")
    }

    /// There is no dedicated enable/disable route — `enabled` is an ordinary writable field on
    /// the same PATCH every other edit uses.
    public func setSchedulerTaskEnabled(taskId: String, fields: TaskWriteFields) async throws -> ScheduledTaskDetail {
        try await updateSchedulerTask(taskId: taskId, fields: fields)
    }

    /// Runs the task right now, bypassing `enabled` (but not `stopped`) — for exercising a task
    /// before it is ever armed. The gate script, if any, still runs and can still decline.
    public func runSchedulerTaskNow(taskId: String) async throws -> TaskRun {
        try await send(path: "/api/scheduler/tasks/\(taskId)/run-now", method: "POST")
    }

    /// Closes the task's current session if still open and clears its link — the old conversation
    /// stays intact and readable, but the next fire starts fresh.
    public func resetSchedulerTask(taskId: String) async throws -> ScheduledTaskDetail {
        try await send(path: "/api/scheduler/tasks/\(taskId)/reset", method: "POST")
    }

    /// Lifts a supervisor's stop — one call clears both the task's refusal to fire and the
    /// supervision's refusal to let the session resume; there is no way to lift either alone.
    public func clearSchedulerTaskStop(taskId: String) async throws -> ScheduledTaskDetail {
        try await send(path: "/api/scheduler/tasks/\(taskId)/clear-stop", method: "POST")
    }

    public func listSchedulerTaskRuns(
        taskId: String, limit: Int? = nil, offset: Int? = nil
    ) async throws -> SchedulerTaskRunsResponse {
        var query: [URLQueryItem] = []
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let offset { query.append(URLQueryItem(name: "offset", value: String(offset))) }
        return try await send(path: "/api/scheduler/tasks/\(taskId)/runs", query: query)
    }

    /// Runs the gate script once against an already-saved task, sending the editor's current,
    /// possibly-unsaved source rather than the task's own saved one — what makes writing a gate
    /// iterative instead of costing a real fire.
    public func testRunSchedulerGate(
        taskId: String, gateSource: String, gateRuntime: TaskGateRuntime
    ) async throws -> SchedulerTestRunResult {
        struct Body: Encodable {
            let gateSource: String
            let gateRuntime: TaskGateRuntime
            enum CodingKeys: String, CodingKey {
                case gateSource = "gate_source"
                case gateRuntime = "gate_runtime"
            }
        }
        return try await send(
            path: "/api/scheduler/tasks/\(taskId)/test-run", method: "POST",
            body: try Self.jsonBody(Body(gateSource: gateSource, gateRuntime: gateRuntime))
        )
    }

    /// Mints or rotates the task's webhook token — shown once in the response and never again.
    /// Refused (400) unless the task's own environment is one the backend considers scoped.
    public func createSchedulerWebhook(taskId: String) async throws -> SchedulerWebhookToken {
        try await send(path: "/api/scheduler/tasks/\(taskId)/webhook", method: "POST")
    }

    public func revokeSchedulerWebhook(taskId: String) async throws {
        try await sendDiscardingResponse(path: "/api/scheduler/tasks/\(taskId)/webhook", method: "DELETE")
    }

    // MARK: Supervision

    /// The supervision watching a session, if any — a session-menu button reads this to decide
    /// whether to open an existing supervisor read-only or offer to attach one.
    public func getSupervisionBySession(sessionId: String) async throws -> SupervisionBySessionResponse {
        try await send(path: "/api/supervisions/by-session/\(sessionId)")
    }

    /// A supervision's own configuration, state, and verdict history.
    public func getSupervision(supervisionId: String) async throws -> SupervisionDetail {
        try await send(path: "/api/supervisions/\(supervisionId)")
    }

    /// Attaches a supervisor to any session — the one write this router offers. `appendPrompt`
    /// left `nil` stores the module's own default text server-side rather than an empty box.
    public func attachSupervision(
        sessionId: String, model: String? = nil, appendPrompt: String? = nil,
        compactionThresholdTokens: Int? = nil, chunkIntervalSeconds: Int? = nil,
        chunkTokenThreshold: Int? = nil
    ) async throws -> Supervision {
        struct Body: Encodable {
            let sessionId: String
            let model: String?
            let appendPrompt: String?
            let compactionThresholdTokens: Int?
            let chunkIntervalSeconds: Int?
            let chunkTokenThreshold: Int?
            enum CodingKeys: String, CodingKey {
                case sessionId = "session_id"
                case model
                case appendPrompt = "append_prompt"
                case compactionThresholdTokens = "compaction_threshold_tokens"
                case chunkIntervalSeconds = "chunk_interval_seconds"
                case chunkTokenThreshold = "chunk_token_threshold"
            }
        }
        return try await send(
            path: "/api/supervisions",
            method: "POST",
            body: try Self.jsonBody(
                Body(
                    sessionId: sessionId, model: model, appendPrompt: appendPrompt,
                    compactionThresholdTokens: compactionThresholdTokens,
                    chunkIntervalSeconds: chunkIntervalSeconds, chunkTokenThreshold: chunkTokenThreshold))
        )
    }

    /// Detaches a supervisor: stops its own session and ends the binding, but keeps the
    /// supervision row, its verdict history and its transcript — so what it decided stays
    /// readable even after detaching.
    public func deleteSupervision(supervisionId: String) async throws -> PaiSupervisionDetachResult {
        try await send(path: "/api/supervisions/\(supervisionId)", method: "DELETE", body: nil, contentType: nil)
    }

    // MARK: Auth

    public func getMe() async throws -> MeResponse {
        try await send(path: "/api/me")
    }

    // MARK: VM folder browsing & favorites

    /// `agent` matters: every browsable path is a `/home/frederik/...` path that exists on both
    /// machines and means a different tree on each, so browsing the VM while launching on the
    /// laptop would pick a directory that is not the one shown.
    public func browse(path: String? = nil, agent: String? = nil) async throws -> BrowseResult {
        var query: [URLQueryItem] = []
        if let path { query.append(URLQueryItem(name: "path", value: path)) }
        if let agent { query.append(URLQueryItem(name: "agent", value: agent)) }
        return try await send(path: "/api/browse", query: query)
    }

    public func getFavorites() async throws -> [FolderFavorite] {
        try await send(path: "/api/favorites")
    }

    public func addFavorite(path: String) async throws -> FolderFavorite {
        struct Body: Encodable { let path: String }
        return try await send(
            path: "/api/favorites",
            method: "POST",
            body: try Self.jsonBody(Body(path: path))
        )
    }

    public func removeFavorite(path: String) async throws -> PaiFavoriteRemovalResult {
        struct Body: Encodable { let path: String }
        return try await send(
            path: "/api/favorites",
            method: "DELETE",
            body: try Self.jsonBody(Body(path: path))
        )
    }

    // MARK: Blocker

    public func answerBlocker(sessionId: String, key: String) async throws -> AnswerBlockerResponse {
        struct Body: Encodable { let key: String }
        return try await send(
            path: "/api/session/\(sessionId)/blocker/answer",
            method: "POST",
            body: try Self.jsonBody(Body(key: key))
        )
    }

    // MARK: App secrets

    public func getSecretStatuses() async throws -> SecretStatusMap {
        try await send(path: "/api/settings/secrets")
    }

    public func setSecret(name: SecretName, value: String) async throws -> SecretStatus {
        struct Body: Encodable { let value: String }
        return try await send(
            path: "/api/settings/secrets/\(name.rawValue)",
            method: "PUT",
            body: try Self.jsonBody(Body(value: value))
        )
    }

    public func clearSecret(name: SecretName) async throws -> PaiSecretRemovalResult {
        try await send(
            path: "/api/settings/secrets/\(name.rawValue)", method: "DELETE", body: nil, contentType: nil
        )
    }

    // MARK: SMTP settings

    public func getSmtpSettings() async throws -> SmtpSettings {
        try await send(path: "/api/settings/smtp")
    }

    public func updateSmtpSettings(_ update: SmtpSettingsUpdate) async throws -> SmtpSettings {
        try await send(path: "/api/settings/smtp", method: "PUT", body: try Self.jsonBody(update))
    }

    /// Sends one real test mail through the currently saved settings — not this in-flight draft,
    /// which is why the caller must save first.
    public func testSmtpSettings() async throws -> PaiSmtpTestResult {
        try await send(path: "/api/settings/smtp/test", method: "POST", body: nil, contentType: nil)
    }

    // MARK: Voice token

    /// Mints a single-use, short-lived ElevenLabs token for the app's own STT call — the app
    /// never asks Freddy for that key directly.
    public func mintVoiceToken(purpose: VoiceTokenPurpose) async throws -> VoiceToken {
        struct Body: Encodable { let purpose: String }
        return try await send(
            path: "/api/voice/token",
            method: "POST",
            body: try Self.jsonBody(Body(purpose: purpose.rawValue))
        )
    }

    // MARK: Claude sign-in on the VM

    public func getClaudeAuth() async throws -> ClaudeAuth {
        try await send(path: "/api/auth/claude")
    }

    /// Begin a sign-in, or rejoin the one already in flight. Safe to call twice.
    public func startClaudeLogin() async throws -> ClaudeAuth {
        try await send(path: "/api/auth/claude/login", method: "POST", body: nil, contentType: nil)
    }

    public func submitClaudeLoginCode(loginId: String, code: String) async throws -> ClaudeLoginCodeResponse {
        struct Body: Encodable {
            let loginId: String
            let code: String
            enum CodingKeys: String, CodingKey { case loginId = "login_id"; case code }
        }
        return try await send(
            path: "/api/auth/claude/login/code",
            method: "POST",
            body: try Self.jsonBody(Body(loginId: loginId, code: code))
        )
    }

    public func cancelClaudeLogin() async throws -> ClaudeAuth {
        try await send(path: "/api/auth/claude/login/cancel", method: "POST", body: nil, contentType: nil)
    }

    // MARK: VM shell / terminal

    /// Start the VM's debug shell, or adopt the one already running. Asking again is harmless —
    /// the shell on screen is never replaced by re-opening the view.
    public func openVmShell() async throws -> PaiVmShellHandle {
        try await send(path: "/api/shell", method: "POST", body: nil, contentType: nil)
    }

    /// Kill the VM's debug shell, losing whatever was running in it.
    public func closeVmShell() async throws {
        try await sendDiscardingResponse(path: "/api/shell", method: "DELETE", body: nil, contentType: nil)
    }

    /// Raw key data from the terminal view's input handler: plain characters, control sequences.
    ///
    /// `literal` is what tells the pane's own prompt a line break from a submit — a synthesized
    /// Enter keypress and a literal carriage return deliver the identical byte to the program on
    /// the other end, so the distinction is purely whether it arrives bundled with other input or
    /// alone in its own read. Omitted or `false` is today's behaviour exactly: a bare `\r` submits.
    /// `true` is for the soft keyboard's own Return, which needs the opposite — a line break, not
    /// a submit — see `TerminalKeyBytes.submit`'s own doc comment for the full mechanism.
    public func sendTerminalInput(sessionId: String, data: String, literal: Bool = false) async throws {
        struct Body: Encodable { let data: String; let literal: Bool }
        try await sendDiscardingResponse(
            path: "/api/session/\(sessionId)/terminal/input",
            method: "POST",
            body: try Self.jsonBody(Body(data: data, literal: literal))
        )
    }

    /// Move a subscribed terminal's capture anchor. Nothing to return — the resulting frame
    /// arrives on the SSE stream the caller already has open.
    public func sendTerminalScroll(sessionId: String, direction: PaiTerminalScrollDirection) async throws {
        struct Body: Encodable { let direction: String }
        try await sendDiscardingResponse(
            path: "/api/session/\(sessionId)/terminal/scroll",
            method: "POST",
            body: try Self.jsonBody(Body(direction: direction.rawValue))
        )
    }

    // MARK: Export & attachments — deliberately bypass the JSON path

    /// Raw bytes plus the server-assigned `Content-Disposition` filename — `send()` always
    /// decodes JSON, which a file download is not.
    public func exportSession(sessionId: String, since: String? = nil) async throws -> PaiExportResult {
        var query: [URLQueryItem] = []
        if let since { query.append(URLQueryItem(name: "since", value: since)) }
        let request = try requestFactory.makeRequest(path: "/api/session/\(sessionId)/export", query: query)
        let (data, response) = try await urlSession.data(for: request)
        try checkStatus(response: response, data: data)
        let filename =
            (response as? HTTPURLResponse)
            .flatMap { $0.value(forHTTPHeaderField: "Content-Disposition") }
            .flatMap(Self.parseContentDispositionFilename)
            ?? "pai-session-\(sessionId)-export.json"
        return PaiExportResult(data: data, filename: filename)
    }

    /// The filename the server assigned, read off the response rather than reconstructed here,
    /// so the naming scheme stays defined in exactly one place: the server
    /// (`web/src/utils/export.ts`'s `parseContentDispositionFilename`, which this mirrors).
    /// Internal rather than `private` so it is directly testable.
    static func parseContentDispositionFilename(_ header: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"filename="?([^";]+)"?"#) else { return nil }
        let range = NSRange(header.startIndex..., in: header)
        guard let match = regex.firstMatch(in: header, range: range),
            let group = Range(match.range(at: 1), in: header)
        else { return nil }
        return String(header[group])
    }

    /// Fetches an image Freddy attached, by its VM path. Never called just because a message
    /// mounts — only on the viewer's own request, so scrolling past a session full of photos
    /// costs nothing.
    public func getAttachment(sessionId: String, path: String) async throws -> PaiAttachmentResult {
        let request = try requestFactory.makeRequest(
            path: "/api/session/\(sessionId)/attachment",
            query: [URLQueryItem(name: "path", value: path)]
        )
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PaiError.transport("Response was not HTTP")
        }
        if http.statusCode == 404 { return .notFound }
        guard (200..<300).contains(http.statusCode) else {
            return .error(PaiError.from(statusCode: http.statusCode, body: data))
        }
        return .ok(data: data, contentType: http.value(forHTTPHeaderField: "Content-Type"))
    }

    // MARK: - Devices

    /// Tells the backend which device to push a notification to.
    ///
    /// Upserted on the token itself rather than on a device id, so re-registering the same
    /// device never creates a second row, and the server normalises case and whitespace before
    /// storing — this client sends the token exactly as APNs issued it and lets the server
    /// decide what equality means.
    /// Registers this device's APNs token and the channels it has switched off.
    ///
    /// The muted list is always sent, empty included: the backend reads an absent field as "leave
    /// whatever this device already chose alone", which is right for a client that does not know
    /// about channels and wrong for one clearing its last mute.
    public func registerDevice(token: String, mutedChannels: [PushChannel]) async throws -> DeviceRegistration {
        struct Body: Encodable {
            let token: String
            let mutedChannels: [String]

            enum CodingKeys: String, CodingKey {
                case token
                case mutedChannels = "muted_channels"
            }
        }
        return try await send(
            path: "/api/devices/register",
            method: "POST",
            body: try Self.jsonBody(Body(token: token, mutedChannels: mutedChannels.map(\.rawValue)))
        )
    }

    // MARK: Alerts

    private struct ClearAlertsResponse: Decodable {
        let cleared: Int
    }

    /// Acknowledges specific alerts, freeing their key so the next occurrence raises fresh rather
    /// than folding onto the old one. `ids` is always sent explicitly and never empty — the
    /// backend reads an *absent* `ids` field as "clear every active alert", which is exactly the
    /// destructive default this app's one caller (the notification centre's per-row Clear
    /// button, row 5.27) must never trigger by accident.
    @discardableResult
    public func clearAlerts(ids: [String]) async throws -> Int {
        struct Body: Encodable { let ids: [String] }
        let response: ClearAlertsResponse = try await send(
            path: "/api/alerts/clear", method: "POST", body: try Self.jsonBody(Body(ids: ids))
        )
        return response.cleared
    }

    // MARK: Notifications

    /// The feed, newest first. `beforeId` walks further back for the next page — an opaque
    /// cursor by id, like the rest of this file's paged endpoints, never an offset (rows can
    /// arrive while paging).
    public func getNotifications(
        limit: Int? = nil, beforeId: String? = nil, kind: PaiNotificationKind? = nil
    ) async throws -> NotificationsResponse {
        var query: [URLQueryItem] = []
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let beforeId { query.append(URLQueryItem(name: "before_id", value: beforeId)) }
        if let kind { query.append(URLQueryItem(name: "kind", value: kind.rawValue)) }
        return try await send(path: "/api/notifications", query: query)
    }

    /// What a badge renders from without opening the centre, and what self-heals it if a live
    /// update was ever missed — see `pai_cloud.api`'s own doc comment on the route.
    public func getNotificationsSummary() async throws -> NotificationSummary {
        try await send(path: "/api/notifications/summary")
    }

    /// One notification, resolving its transcript anchor first if it was still pending — this is
    /// the call a tapped push notification makes at tap time, since the payload only ever carries
    /// the notification's own id (see `DeepLink.notification`'s doc comment).
    public func getNotification(id: String) async throws -> PaiNotification {
        try await send(path: "/api/notifications/\(id)")
    }

    private struct MarkNotificationsReadResponse: Decodable {
        let marked: Int
    }

    /// Marks specific notifications read. Returns how many rows actually changed — fewer than
    /// `ids.count` when some were already read, which is not an error.
    @discardableResult
    public func markNotificationsRead(ids: [String]) async throws -> Int {
        struct Body: Encodable { let ids: [String] }
        let response: MarkNotificationsReadResponse = try await send(
            path: "/api/notifications/read", method: "POST", body: try Self.jsonBody(Body(ids: ids))
        )
        return response.marked
    }

    /// Marks every unread notification read. There is deliberately no way to mark one back
    /// unread — the backend exposes no such mutation, matching a plain "I saw this" log rather
    /// than a mailbox with per-message state to toggle.
    @discardableResult
    public func markAllNotificationsRead() async throws -> Int {
        struct Body: Encodable { let all: Bool }
        let response: MarkNotificationsReadResponse = try await send(
            path: "/api/notifications/read", method: "POST", body: try Self.jsonBody(Body(all: true))
        )
        return response.marked
    }
}
