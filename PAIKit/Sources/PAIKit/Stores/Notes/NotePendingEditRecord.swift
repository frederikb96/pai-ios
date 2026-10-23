import Foundation

/// A pending edit as it is written to disk, version 1.
///
/// 🚨 This is the only copy of what was typed, so it must stay readable across app updates. It is
/// its own type with every key spelled out, never a wire model: a field the server starts sending,
/// or a property renamed in ``NoteDetail``, must not change what this file looks like. Everything
/// except the note id, the typed body and the base's body and hash decodes as optional, so a
/// record missing a field the store could do without still restores. A file written by a newer
/// format (`version` above 1) is refused rather than half-read; the storage then quarantines it.
///
/// `Tests/PAIKitTests/Resources/note-pending-edit-v1.json` is a frozen record of this format.
/// Decoding it is a test, so a change here that would strand an edit already on a phone goes red.
struct NotePendingEditRecordV1: Codable, Equatable {
    static let currentVersion = 1

    struct Base: Codable, Equatable {
        var id: String?
        var name: String?
        var summary: String?
        var containerId: String?
        var favourite: Bool?
        var tags: [String]?
        var updatedAtMs: Int?
        var pendingDelete: Bool?
        var frontmatter: String?
        var body: String
        var contentHash: String
        var createdAt: String?
        var createdAtMs: Int?
        var lastWriteSource: String?
        var shared: Bool?

        enum CodingKeys: String, CodingKey {
            case id, name, summary, favourite, tags, frontmatter, body, shared
            case containerId = "container_id"
            case updatedAtMs = "updated_at_ms"
            case pendingDelete = "pending_delete"
            case contentHash = "content_hash"
            case createdAt = "created_at"
            case createdAtMs = "created_at_ms"
            case lastWriteSource = "last_write_source"
        }
    }

    struct Conflict: Codable, Equatable {
        /// Optional so a damaged conflict costs only the conflict: without it the edit is sent as
        /// an ordinary save, which raises the banner again if the note still differs.
        var currentHash: String?
        var updatedAtMs: Int?
        var frontmatter: String?
        var body: String?

        enum CodingKeys: String, CodingKey {
            case frontmatter, body
            case currentHash = "current_hash"
            case updatedAtMs = "updated_at_ms"
        }
    }

    var version: Int?
    var noteId: String
    var body: String
    var base: Base
    var editedAtMs: Int?
    var attempts: Int?
    var raisedConflict: Conflict?
    var awaitingSync: Bool?
    var waitedForServer: Bool?
    var refusal: String?

    enum CodingKeys: String, CodingKey {
        case version, noteId, body, base, editedAtMs, attempts, raisedConflict, awaitingSync, waitedForServer, refusal
    }

    struct UnknownVersion: Error {
        let version: Int
    }

    init(_ edit: NotePendingEdit) {
        let detail = edit.base
        version = Self.currentVersion
        noteId = edit.noteId
        body = edit.body
        base = Base(
            id: detail.id, name: detail.name, summary: detail.summary, containerId: detail.containerId,
            favourite: detail.favourite, tags: detail.tags, updatedAtMs: detail.updatedAtMs,
            pendingDelete: detail.pendingDelete, frontmatter: detail.frontmatter, body: detail.body,
            contentHash: detail.contentHash, createdAt: detail.createdAt, createdAtMs: detail.createdAtMs,
            lastWriteSource: detail.lastWriteSource, shared: detail.shared)
        editedAtMs = edit.editedAtMs
        attempts = edit.attempts
        raisedConflict = edit.raisedConflict.map {
            Conflict(
                currentHash: $0.currentHash, updatedAtMs: $0.updatedAtMs, frontmatter: $0.frontmatter, body: $0.body)
        }
        awaitingSync = edit.awaitingSync
        waitedForServer = edit.waitedForServer
        refusal = edit.refusal
    }

    /// Reads a record, refusing one written by a newer format.
    static func decode(_ data: Data) throws -> NotePendingEdit {
        let record = try JSONDecoder().decode(Self.self, from: data)
        let version = record.version ?? currentVersion
        guard version <= currentVersion else { throw UnknownVersion(version: version) }
        return record.edit
    }

    var edit: NotePendingEdit {
        let detail = NoteDetail(
            id: base.id ?? noteId, name: base.name ?? NoteNaming.untitled, summary: base.summary,
            containerId: base.containerId, favourite: base.favourite ?? false, tags: base.tags ?? [],
            updatedAtMs: base.updatedAtMs ?? 0, pendingDelete: base.pendingDelete ?? false,
            frontmatter: base.frontmatter, body: base.body, contentHash: base.contentHash,
            createdAt: base.createdAt, createdAtMs: base.createdAtMs, lastWriteSource: base.lastWriteSource,
            shared: base.shared)
        let conflict = raisedConflict.flatMap { raised in
            raised.currentHash.map {
                NoteConflict(
                    currentHash: $0, updatedAtMs: raised.updatedAtMs ?? 0, frontmatter: raised.frontmatter,
                    body: raised.body)
            }
        }
        return NotePendingEdit(
            noteId: noteId, body: body, base: detail, editedAtMs: editedAtMs ?? 0, attempts: attempts ?? 0,
            raisedConflict: conflict, awaitingSync: awaitingSync ?? false, waitedForServer: waitedForServer ?? false,
            refusal: refusal)
    }
}
