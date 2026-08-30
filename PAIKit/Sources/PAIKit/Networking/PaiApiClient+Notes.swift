import Foundation

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

    public func getNoteContainers() async throws -> [NoteContainer] {
        let page: NoteContainersPage = try await send(path: "/api/notes/containers")
        return page.containers
    }

    // MARK: Envelopes

    struct NotesPage: Decodable, Sendable {
        let notes: [NoteSummary]
    }

    struct NoteContainersPage: Decodable, Sendable {
        let containers: [NoteContainer]
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
}
