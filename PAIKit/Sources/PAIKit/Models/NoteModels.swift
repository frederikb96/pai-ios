import Foundation

/// Swift port of `pai-cloud/web/src/api/types.ts` (the "Notes" section).
/// `pai-cloud` owns this contract; this file mirrors it rather than redefining it.

/// A note as the list route returns it — no `body`, so listing a vault stays cheap enough to
/// load eagerly.
public struct NoteSummary: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let name: String
    /// The one-line description lifted out of the note's frontmatter. Absent on a note whose
    /// frontmatter never carried one.
    public let summary: String?
    /// `nil` for a note that lives only in the database and has never been written to disk.
    public let containerId: String?
    public let favourite: Bool
    public let tags: [String]
    public let updatedAtMs: Int
    /// Marked for deletion and still recoverable. The list keeps showing it, dimmed, because
    /// undelete is a route and a note that vanished has no affordance to bring it back.
    public let pendingDelete: Bool

    public init(
        id: String, name: String, summary: String?, containerId: String?, favourite: Bool,
        tags: [String], updatedAtMs: Int, pendingDelete: Bool
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.containerId = containerId
        self.favourite = favourite
        self.tags = tags
        self.updatedAtMs = updatedAtMs
        self.pendingDelete = pendingDelete
    }

    enum CodingKeys: String, CodingKey {
        case id, name, summary, favourite, tags
        case containerId = "container_id"
        case updatedAtMs = "updated_at_ms"
        case pendingDelete = "pending_delete"
    }
}

/// One note with its content. `frontmatter` is the raw YAML block as stored, opaque to this app:
/// it is Freddy's vault metadata, and a round trip through any parser rewrites it. Carry the
/// string through a save unchanged unless the user is editing that block itself.
public struct NoteDetail: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let summary: String?
    public let containerId: String?
    public let favourite: Bool
    public let tags: [String]
    public let updatedAtMs: Int
    public let pendingDelete: Bool
    public let frontmatter: String?
    public let body: String
    /// What a conditional save must send back as `expectedHash`. The server compares it against
    /// what it holds and answers 409 rather than overwriting — see ``NoteConflict``.
    public let contentHash: String
    public let createdAt: String?
    public let createdAtMs: Int?
    /// Which side wrote this note last (`"ui"`, `"agent"`, …). Nil on a row written before the
    /// column existed; read it as unknown, never as `"ui"`.
    public let lastWriteSource: String?

    public init(
        id: String, name: String, summary: String?, containerId: String?, favourite: Bool,
        tags: [String], updatedAtMs: Int, pendingDelete: Bool, frontmatter: String?, body: String,
        contentHash: String, createdAt: String?, createdAtMs: Int?, lastWriteSource: String?
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.containerId = containerId
        self.favourite = favourite
        self.tags = tags
        self.updatedAtMs = updatedAtMs
        self.pendingDelete = pendingDelete
        self.frontmatter = frontmatter
        self.body = body
        self.contentHash = contentHash
        self.createdAt = createdAt
        self.createdAtMs = createdAtMs
        self.lastWriteSource = lastWriteSource
    }

    enum CodingKeys: String, CodingKey {
        case id, name, summary, favourite, tags, frontmatter, body
        case containerId = "container_id"
        case updatedAtMs = "updated_at_ms"
        case pendingDelete = "pending_delete"
        case contentHash = "content_hash"
        case createdAt = "created_at"
        case createdAtMs = "created_at_ms"
        case lastWriteSource = "last_write_source"
    }

    /// The list-shaped view of this note, so a freshly saved detail can update the list without
    /// a second round trip.
    public var summaryRow: NoteSummary {
        NoteSummary(
            id: id, name: name, summary: summary, containerId: containerId, favourite: favourite,
            tags: tags, updatedAtMs: updatedAtMs, pendingDelete: pendingDelete)
    }
}

/// What a save gets back instead of a note when the server's copy moved on: the 409 body of
/// `PATCH /api/notes/{id}`.
///
/// Only a hash mismatch ever answers 409 on that route — a rename collision or an invalid name
/// answers 400 — so any 409 from a save is this shape.
public struct NoteConflict: Codable, Sendable, Equatable, Hashable {
    public let currentHash: String
    public let updatedAtMs: Int
    public let frontmatter: String?
    public let body: String?

    public init(currentHash: String, updatedAtMs: Int, frontmatter: String?, body: String?) {
        self.currentHash = currentHash
        self.updatedAtMs = updatedAtMs
        self.frontmatter = frontmatter
        self.body = body
    }

    enum CodingKeys: String, CodingKey {
        case frontmatter, body
        case currentHash = "current_hash"
        case updatedAtMs = "updated_at_ms"
    }
}

/// A directory on a machine that a set of notes is synced to and from.
public struct NoteContainer: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    /// Which machine holds the directory — a `Machine`'s `slug`.
    public let agentSlug: String
    public let path: String
    public let name: String
    public let enabled: Bool
    public let isDefault: Bool
    /// `"idle"`, `"scanning"`, `"paused"`, … — an open vocabulary, so it stays a `String`.
    public let state: String
    public let pausedReason: String?
    public let lastScanAtMs: Int?
    public let lastError: String?
    public let noteCount: Int
    public let createdAt: String?
    public let updatedAt: String?

    public init(
        id: String, agentSlug: String, path: String, name: String, enabled: Bool, isDefault: Bool,
        state: String, pausedReason: String?, lastScanAtMs: Int?, lastError: String?,
        noteCount: Int, createdAt: String?, updatedAt: String?
    ) {
        self.id = id
        self.agentSlug = agentSlug
        self.path = path
        self.name = name
        self.enabled = enabled
        self.isDefault = isDefault
        self.state = state
        self.pausedReason = pausedReason
        self.lastScanAtMs = lastScanAtMs
        self.lastError = lastError
        self.noteCount = noteCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, path, name, enabled, state
        case agentSlug = "agent_slug"
        case isDefault = "is_default"
        case pausedReason = "paused_reason"
        case lastScanAtMs = "last_scan_at_ms"
        case lastError = "last_error"
        case noteCount = "note_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
