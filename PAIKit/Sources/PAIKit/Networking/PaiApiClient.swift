import Foundation

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

    public init(requestFactory: PaiRequestFactory, urlSession: URLSession = .shared) {
        self.requestFactory = requestFactory
        self.urlSession = urlSession
    }

    // MARK: Core request helpers

    private func send<T: Decodable>(
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
    private func sendDiscardingResponse(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = "application/json"
    ) async throws {
        _ = try await sendRaw(path: path, method: method, query: query, body: body, contentType: contentType)
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
        try Self.checkStatus(response: response, data: data)
        return (data, response)
    }

    private static func checkStatus(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PaiError.transport("Response was not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PaiError.from(statusCode: http.statusCode, body: data)
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
        try Self.checkStatus(response: response, data: data)
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

    /// Send a message. Omitting `sessionId` **creates** the session — one path serves both the
    /// New Session screen and an existing chat (`client.ts:81-104`).
    public func postMessage(
        sessionId: String? = nil,
        message: String,
        files: [PaiFileUpload] = [],
        sessionType: String? = nil,
        workingDir: String? = nil,
        agent: String? = nil
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

    /// Move a session to an existing project, landing it in a fresh blank phase.
    public func switchSessionProject(sessionId: String, projectId: String) async throws -> Session {
        struct Body: Encodable {
            let projectId: String
            enum CodingKeys: String, CodingKey { case projectId = "project_id" }
        }
        return try await send(
            path: "/api/session/\(sessionId)/switch-project",
            method: "POST",
            body: try Self.jsonBody(Body(projectId: projectId))
        )
    }

    /// Move a session to an existing phase within its current project.
    public func switchSessionPhase(sessionId: String, phaseId: String) async throws -> Session {
        struct Body: Encodable {
            let phaseId: String
            enum CodingKeys: String, CodingKey { case phaseId = "phase_id" }
        }
        return try await send(
            path: "/api/session/\(sessionId)/switch-phase",
            method: "POST",
            body: try Self.jsonBody(Body(phaseId: phaseId))
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
        workingDir: String? = nil
    ) async throws -> PutDraftResult {
        struct Body: Encodable {
            let text: String
            let sessionType: String?
            let workingDir: String?
            enum CodingKeys: String, CodingKey {
                case text
                case sessionType = "session_type"
                case workingDir = "working_dir"
            }
        }
        return try await send(
            path: "/api/drafts/\(Self.encodeDraftKey(key))",
            method: "PUT",
            body: try Self.jsonBody(Body(text: text, sessionType: sessionType, workingDir: workingDir))
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
    public func sendTerminalInput(sessionId: String, data: String) async throws {
        struct Body: Encodable { let data: String }
        try await sendDiscardingResponse(
            path: "/api/session/\(sessionId)/terminal/input",
            method: "POST",
            body: try Self.jsonBody(Body(data: data))
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
        try Self.checkStatus(response: response, data: data)
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
}
