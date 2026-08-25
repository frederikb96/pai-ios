import Foundation

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

public struct PaiShareRemovalResult: Codable, Sendable, Equatable {
    public let removed: Bool
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

    public func getSessions(since: String? = nil, limit: Int? = nil) async throws -> [Session] {
        var query: [URLQueryItem] = []
        if let since { query.append(URLQueryItem(name: "since", value: since)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await send(path: "/api/sessions", query: query)
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
        workingDir: String? = nil
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

    // MARK: Auth / sharing

    public func getMe() async throws -> MeResponse {
        try await send(path: "/api/me")
    }

    public func getKnownUsers() async throws -> [KnownUser] {
        try await send(path: "/api/known-users")
    }

    public func getSessionShares(sessionId: String) async throws -> [SessionShare] {
        try await send(path: "/api/session/\(sessionId)/shares")
    }

    public func shareSession(sessionId: String, email: String) async throws -> SessionShare {
        struct Body: Encodable { let email: String }
        return try await send(
            path: "/api/session/\(sessionId)/share",
            method: "POST",
            body: try Self.jsonBody(Body(email: email))
        )
    }

    public func unshareSession(sessionId: String, email: String) async throws -> PaiShareRemovalResult {
        struct Body: Encodable { let email: String }
        return try await send(
            path: "/api/session/\(sessionId)/share",
            method: "DELETE",
            body: try Self.jsonBody(Body(email: email))
        )
    }

    // MARK: VM folder browsing & favorites

    public func browse(path: String? = nil) async throws -> BrowseResult {
        var query: [URLQueryItem] = []
        if let path { query.append(URLQueryItem(name: "path", value: path)) }
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
