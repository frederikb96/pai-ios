import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// What a note attachment fetch came back as — `notFound` kept distinct from a real error,
/// mirroring `PaiAttachmentResult`: on the VM the vault syncs markdown only, so a missing binary
/// is the ordinary, permanent case of "this one lives on the laptop", not something a retry fixes.
public enum NoteAttachmentResult: Sendable {
    case ok(Data)
    case notFound
}

/// What a conditional note save came back as.
///
/// A conflict is a normal outcome rather than an error: the reader has to be shown both versions
/// and asked, so it travels as a value the caller must handle, not as something a `catch` can
/// swallow into a generic failure message.
public enum NoteSaveResult: Sendable, Equatable {
    case saved(NoteDetail)
    case conflict(NoteConflict)
}

extension PaiApiClient {

    // MARK: Notes

    public func getNotesConfig() async throws -> NotesConfig {
        try await send(path: "/api/notes/config")
    }

    /// The whole index, metadata only. The web loads it eagerly and filters client-side rather
    /// than paging, because a vault is small enough and every filter is then instant; this
    /// mirrors that, which is why the default limit is the route's own maximum page rather than
    /// a screenful.
    public func getNotes(
        containerId: String? = nil,
        favourite: Bool? = nil,
        limit: Int = 500,
        offset: Int = 0
    ) async throws -> [NoteSummary] {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let containerId { query.append(URLQueryItem(name: "container_id", value: containerId)) }
        if let favourite { query.append(URLQueryItem(name: "favourite", value: favourite ? "true" : "false")) }
        let page: NotesPage = try await send(path: "/api/notes", query: query)
        return page.notes
    }

    public func getNote(id: String) async throws -> NoteDetail {
        try await send(path: "/api/notes/\(id)")
    }

    /// Create a note. Obsidian's own convention: a brand new note is a real file the moment it
    /// is created, not a draft that only becomes one on first keystroke.
    ///
    /// `containerId` omitted falls back to the server's default container, if one is registered
    /// — otherwise the note is created DB-only and never reaches disk (mirrors
    /// `create_note_route`'s own fallback, so this client need not duplicate "which container is
    /// default" logic).
    public func createNote(
        name: String, summary: String? = nil, body: String? = nil, containerId: String? = nil
    ) async throws -> NoteDetail {
        var payload: [String: JSONValue] = ["name": .string(name)]
        if let summary { payload["summary"] = .string(summary) }
        if let body { payload["body"] = .string(body) }
        if let containerId { payload["container_id"] = .string(containerId) }
        return try await send(path: "/api/notes", method: "POST", body: try Self.encodeJSON(payload))
    }

    /// Save a note's content, conditional on `expectedHash` still being what the server holds.
    ///
    /// Passing `nil` for `expectedHash` makes the write unconditional, which is what a
    /// conflict resolution that has chosen "mine" does — everything else must pass the hash it
    /// last read, or a save silently discards whatever arrived from the vault in between.
    ///
    /// `frontmatter` is sent back byte-for-byte as it was read. It is Freddy's own vault
    /// metadata and nothing in this app understands it; omitting it from a save is not the same
    /// as leaving it alone on this route, which merges by key presence.
    public func patchNote(
        id: String,
        body: String? = nil,
        frontmatter: String? = nil,
        name: String? = nil,
        summary: String? = nil,
        favourite: Bool? = nil,
        containerId: String? = nil,
        expectedHash: String?
    ) async throws -> NoteSaveResult {
        var payload: [String: JSONValue] = [:]
        if let body { payload["body"] = .string(body) }
        if let frontmatter { payload["frontmatter"] = .string(frontmatter) }
        if let name { payload["name"] = .string(name) }
        if let summary { payload["summary"] = .string(summary) }
        if let favourite { payload["favourite"] = .bool(favourite) }
        if let containerId { payload["container_id"] = .string(containerId) }
        if let expectedHash { payload["expected_hash"] = .string(expectedHash) }

        let (status, data) = try await sendPassingThrough(
            path: "/api/notes/\(id)", method: "PATCH", body: try Self.encodeJSON(payload),
            passthrough: [409])
        do {
            if status == 409 {
                return .conflict(try JSONDecoder().decode(NoteConflict.self, from: data))
            }
            return .saved(try JSONDecoder().decode(NoteDetail.self, from: data))
        } catch {
            throw PaiError.decoding("\(error)")
        }
    }

    /// Mark a note favourite without touching its content — a separate path on the server, which
    /// skips the hash recompute entirely, so it must not carry an `expected_hash`.
    public func setNoteFavourite(id: String, favourite: Bool) async throws -> NoteDetail {
        try await send(
            path: "/api/notes/\(id)", method: "PATCH",
            body: try Self.encodeJSON(["favourite": .bool(favourite)]))
    }

    /// Start the confirm-then-undo window — the row, its embedding and its file are all
    /// untouched until the server's finalizer fires. Returns whether the note is now pending
    /// delete; a note already gone answers 404, which `send` turns into a thrown `PaiError`.
    public func deleteNote(id: String) async throws -> Bool {
        struct Body: Decodable, Sendable {
            let pendingDelete: Bool
            enum CodingKeys: String, CodingKey { case pendingDelete = "pending_delete" }
        }
        let result: Body = try await send(path: "/api/notes/\(id)", method: "DELETE", body: nil, contentType: nil)
        return result.pendingDelete
    }

    public func undeleteNote(id: String) async throws -> NoteDetail {
        try await send(path: "/api/notes/\(id)/undelete", method: "POST", body: nil, contentType: nil)
    }

    // MARK: The link index

    /// A note's resolved outgoing links and its backlinks, in one call — the panel shows both,
    /// and a second round trip on a phone is a visible delay.
    public func getNoteLinks(id: String) async throws -> NoteLinkGraph {
        try await send(path: "/api/notes/\(id)/links")
    }

    // MARK: Revision history

    public func listNoteRevisions(id: String) async throws -> [NoteRevisionSummary] {
        let page: NoteRevisionsPage = try await send(path: "/api/notes/\(id)/revisions")
        return page.revisions
    }

    public func getNoteRevision(noteId: String, revisionId: String) async throws -> NoteRevisionDetail {
        try await send(path: "/api/notes/\(noteId)/revisions/\(revisionId)")
    }

    /// Writes the old content back as a NEW version rather than rewinding, so restoring is
    /// itself undoable.
    public func restoreNoteRevision(noteId: String, revisionId: String) async throws -> NoteDetail {
        try await send(
            path: "/api/notes/\(noteId)/revisions/\(revisionId)/restore", method: "POST", body: nil,
            contentType: nil)
    }

    // MARK: Full-text search

    /// Literal substring search over note bodies — not stemmed full-text search, since finding
    /// part of an identifier or a path is the point.
    public func searchNotes(q: String, containerId: String? = nil, limit: Int? = nil) async throws -> NoteSearchPage {
        var query = [URLQueryItem(name: "q", value: q)]
        if let containerId { query.append(URLQueryItem(name: "container_id", value: containerId)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await send(path: "/api/notes/search", query: query)
    }

    // MARK: Semantic search

    /// `POST /api/memory/search`, scoped to `filter: {"type": "note"}` — meaning-based search
    /// over the summary each note contributes to memory, ported from the web's `NoteList.tsx`
    /// (`semantic` mode). The route is generic across memories, phase summaries and notes;
    /// nothing here reuses it for those, so this stays a notes-only wrapper rather than a
    /// general memory-search client.
    public func searchNotesSemantic(q: String, limit: Int = 100) async throws -> [NoteSemanticHit] {
        struct Body: Encodable {
            let query: String
            let limit: Int
            let filter: [String: String]
        }
        let payload: Data
        do {
            payload = try JSONEncoder().encode(Body(query: q, limit: limit, filter: ["type": "note"]))
        } catch {
            throw PaiError.decoding("\(error)")
        }
        let response: NoteSemanticSearchResponse = try await send(
            path: "/api/memory/search", method: "POST", body: payload)
        return response.results
    }

    // MARK: Containers

    public func getNoteContainers() async throws -> [NoteContainer] {
        let page: NoteContainersPage = try await send(path: "/api/notes/containers")
        return page.containers
    }

    /// Register a container — the server re-validates the path against the agent itself, never
    /// trusting that this call already ran `validateNoteContainerPath` first.
    public func createNoteContainer(
        path: String, name: String, agentSlug: String? = nil, isDefault: Bool = false
    ) async throws -> NoteContainer {
        var payload: [String: JSONValue] = ["path": .string(path), "name": .string(name)]
        if let agentSlug { payload["agent_slug"] = .string(agentSlug) }
        if isDefault { payload["is_default"] = .bool(true) }
        return try await send(path: "/api/notes/containers", method: "POST", body: try Self.encodeJSON(payload))
    }

    public func patchNoteContainer(
        id: String, name: String? = nil, enabled: Bool? = nil, isDefault: Bool? = nil
    ) async throws -> NoteContainer {
        var payload: [String: JSONValue] = [:]
        if let name { payload["name"] = .string(name) }
        if let enabled { payload["enabled"] = .bool(enabled) }
        if let isDefault { payload["is_default"] = .bool(isDefault) }
        return try await send(
            path: "/api/notes/containers/\(id)", method: "PATCH", body: try Self.encodeJSON(payload))
    }

    /// Detach a container. Its notes orphan to DB-only rather than disappearing.
    public func deleteNoteContainer(id: String) async throws -> Bool {
        struct Body: Decodable, Sendable { let deleted: Bool }
        let result: Body = try await send(
            path: "/api/notes/containers/\(id)", method: "DELETE", body: nil, contentType: nil)
        return result.deleted
    }

    /// End a mass-delete or missing-path pause.
    public func resumeNoteContainer(id: String, action: NoteContainerResumeAction) async throws -> NoteContainer {
        try await send(
            path: "/api/notes/containers/\(id)/resume", method: "POST",
            body: try Self.encodeJSON(["action": .string(action.rawValue)]))
    }

    /// Ask the agent whether a path is usable, without creating anything — the preview before
    /// `createNoteContainer`, which re-validates independently rather than trusting this call.
    public func validateNoteContainerPath(
        path: String, agentSlug: String? = nil
    ) async throws -> NoteContainerPathCheck {
        var payload: [String: JSONValue] = ["path": .string(path)]
        if let agentSlug { payload["agent_slug"] = .string(agentSlug) }
        return try await send(
            path: "/api/notes/containers/validate-path", method: "POST", body: try Self.encodeJSON(payload))
    }

    // MARK: Attachments
    //
    // Every `path`/`fromPath`/`toPath` below is CONTAINER-ROOT-relative, e.g.
    // `attachments/x.png` — the same form `NoteAttachmentRecord.relPath` and `NoteLink
    // .targetAttachmentPath` hold. Passed through unchanged; do not strip the prefix.

    /// Fetches an attachment's bytes from the VM, on demand. A missing file is `.notFound`, not
    /// a thrown error — on the VM the vault carries markdown only (Syncthing does not mirror
    /// binaries here), so a laptop-only image is an expected, not exceptional, answer.
    public func getNoteAttachment(containerId: String, path: String) async throws -> NoteAttachmentResult {
        let (status, data) = try await sendPassingThrough(
            path: "/api/notes/containers/\(containerId)/attachment",
            method: "GET", query: [URLQueryItem(name: "path", value: path)], body: nil, contentType: nil,
            passthrough: [404])
        if status == 404 { return .notFound }
        return .ok(data)
    }

    /// Places a file (uploaded, or pasted) into the container's flat `attachments/` folder.
    public func uploadNoteAttachment(
        containerId: String, filename: String, mimeType: String, data: Data
    ) async throws -> NoteAttachmentUploaded {
        let boundary = "PAIKit-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(Self.escapeAttachmentFilename(filename))\"\r\n"
                .data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return try await send(
            path: "/api/notes/containers/\(containerId)/attachments", method: "POST", body: body,
            contentType: "multipart/form-data; boundary=\(boundary)")
    }

    /// The full attachment inventory for one container, each with how many links across it
    /// currently resolve there.
    public func listNoteAttachments(containerId: String) async throws -> [NoteAttachmentRecord] {
        let page: NoteAttachmentsPage = try await send(path: "/api/notes/containers/\(containerId)/attachments")
        return page.attachments
    }

    /// Removes a file from `attachments/` on the VM. Links pointing at it are left alone — they
    /// become broken links, which is visible, rather than being silently edited out of notes.
    public func deleteNoteAttachment(containerId: String, path: String) async throws -> Bool {
        struct Body: Decodable, Sendable { let deleted: Bool }
        let result: Body = try await send(
            path: "/api/notes/containers/\(containerId)/attachment", method: "DELETE",
            query: [URLQueryItem(name: "path", value: path)])
        return result.deleted
    }

    /// Renames a file within `attachments/` and rewrites every link that resolved to it — the
    /// one class of automatic link repair this system performs, because the rename is its own.
    public func renameNoteAttachment(
        containerId: String, fromPath: String, toPath: String
    ) async throws -> NoteAttachmentRecord {
        try await send(
            path: "/api/notes/containers/\(containerId)/attachment/rename", method: "POST",
            body: try Self.encodeJSON(["from_path": .string(fromPath), "to_path": .string(toPath)]))
    }

    /// The whole broken-links screen in one answer — a view only; nothing here is ever acted on
    /// automatically.
    public func getNoteLinkHealth(containerId: String) async throws -> NoteLinkHealth {
        try await send(path: "/api/notes/containers/\(containerId)/link-health")
    }

    // MARK: Envelopes

    struct NotesPage: Decodable, Sendable {
        let notes: [NoteSummary]
    }

    struct NoteContainersPage: Decodable, Sendable {
        let containers: [NoteContainer]
    }

    struct NoteRevisionsPage: Decodable, Sendable {
        let revisions: [NoteRevisionSummary]
    }

    struct NoteAttachmentsPage: Decodable, Sendable {
        let attachments: [NoteAttachmentRecord]
    }

    struct NoteSemanticSearchResponse: Decodable, Sendable {
        let results: [NoteSemanticHit]
    }

    // MARK: Helpers

    /// The notes routes take loose JSON objects whose keys are present-or-absent rather than
    /// present-and-null — "leave this field alone" and "set this field to nothing" are different
    /// requests to them. A `[String: JSONValue]` says exactly which keys were sent;
    /// an `Encodable` struct of optionals cannot, since it would either emit every key or need a
    /// hand-written encoder per shape.
    enum JSONValue: Encodable, Sendable {
        case string(String)
        case bool(Bool)
        case null

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            case .null: try container.encodeNil()
            }
        }
    }

    static func encodeJSON(_ payload: [String: JSONValue]) throws -> Data {
        do {
            return try JSONEncoder().encode(payload)
        } catch {
            throw PaiError.decoding("\(error)")
        }
    }

    /// A filename Freddy picked (from the camera roll, say) can contain `"`, which would
    /// otherwise close the quoted `filename` parameter early. Mirrors `PaiApiClient`'s own
    /// private `escapeContentDispositionValue` — duplicated rather than shared, since that one is
    /// `private` to its file and every route belongs in this extension rather than the base type.
    private static func escapeAttachmentFilename(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
