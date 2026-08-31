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

/// What a mass-delete pause is holding back — shown so it can be acted on rather than merely
/// reported. `names` is a preview, not the whole set.
public struct NoteContainerBreaker: Codable, Sendable, Equatable, Hashable {
    public let pendingDeletions: Int
    public let baselineCount: Int
    public let names: [String]

    public init(pendingDeletions: Int, baselineCount: Int, names: [String]) {
        self.pendingDeletions = pendingDeletions
        self.baselineCount = baselineCount
        self.names = names
    }

    enum CodingKeys: String, CodingKey {
        case names
        case pendingDeletions = "pending_deletions"
        case baselineCount = "baseline_count"
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
    /// `"pending"`, `"active"`, `"paused_mass_delete"`, … — an open vocabulary, so it stays a
    /// `String` rather than an enum a future server-side state would silently fail to decode.
    public let state: String
    public let pausedReason: String?
    public let lastScanAtMs: Int?
    public let lastError: String?
    public let noteCount: Int
    public let breaker: NoteContainerBreaker?
    public let createdAt: String?
    public let updatedAt: String?
    /// What the agent's latest pass could not export, and why. `nil` means the agent has
    /// reported nothing on this connection ("not known yet") — a different claim from `[]`
    /// ("nothing was skipped"). Render them differently.
    public let skipped: [String]?
    public let recent: [String]?

    public init(
        id: String, agentSlug: String, path: String, name: String, enabled: Bool, isDefault: Bool,
        state: String, pausedReason: String?, lastScanAtMs: Int?, lastError: String?,
        noteCount: Int, breaker: NoteContainerBreaker?, createdAt: String?, updatedAt: String?,
        skipped: [String]? = nil, recent: [String]? = nil
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
        self.breaker = breaker
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.skipped = skipped
        self.recent = recent
    }

    enum CodingKeys: String, CodingKey {
        case id, path, name, enabled, state, breaker, skipped, recent
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

/// `POST /api/notes/containers/validate-path` — answered by the agent, which is the only side
/// that can see the filesystem.
public struct NoteContainerPathCheck: Codable, Sendable, Equatable {
    public let ok: Bool
    /// The path after symlinks and `..` are resolved — never the one sent.
    public let resolvedPath: String?
    /// Why not, in words meant for Freddy rather than for a log.
    public let reason: String?
    /// Markdown files already there, so attaching is not a blind act.
    public let existingNotes: Int?

    public init(ok: Bool, resolvedPath: String?, reason: String?, existingNotes: Int?) {
        self.ok = ok
        self.resolvedPath = resolvedPath
        self.reason = reason
        self.existingNotes = existingNotes
    }

    enum CodingKeys: String, CodingKey {
        case ok, reason
        case resolvedPath = "resolved_path"
        case existingNotes = "existing_notes"
    }
}

/// `POST /api/notes/containers/{id}/resume` — the two ways a mass-delete pause can end.
/// `applyDeletions` means the deletions were real; `restoreFiles` means they were not and the
/// database copies win.
public enum NoteContainerResumeAction: String, Sendable, Equatable {
    case applyDeletions = "apply_deletions"
    case restoreFiles = "restore_files"
}

/// `POST /api/notes/containers/{id}/attachments` — the file is written into the container's
/// `attachments/` folder and linked from the note by this path, in Obsidian's own embed form.
public struct NoteAttachmentUploaded: Codable, Sendable, Equatable {
    public let relPath: String
    public let size: Int

    public init(relPath: String, size: Int) {
        self.relPath = relPath
        self.size = size
    }

    enum CodingKeys: String, CodingKey {
        case size
        case relPath = "rel_path"
    }
}

/// One file under a container's `attachments/`. The bytes are never stored in this record; it is
/// what a link-health query and the attachment browser both answer from.
public struct NoteAttachmentRecord: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let relPath: String
    public let basename: String
    /// Lowercase, without the dot. Empty where the file has no extension.
    public let ext: String
    public let sizeBytes: Int
    public let mtimeMs: Int
    /// How many links across the container resolve to this file.
    public let linkCount: Int

    public var id: String { relPath }

    public init(relPath: String, basename: String, ext: String, sizeBytes: Int, mtimeMs: Int, linkCount: Int) {
        self.relPath = relPath
        self.basename = basename
        self.ext = ext
        self.sizeBytes = sizeBytes
        self.mtimeMs = mtimeMs
        self.linkCount = linkCount
    }

    enum CodingKeys: String, CodingKey {
        case basename, ext
        case relPath = "rel_path"
        case sizeBytes = "size_bytes"
        case mtimeMs = "mtime_ms"
        case linkCount = "link_count"
    }
}

/// What a link currently points at. `outside` is a deliberate reference to something above the
/// container root — shown, never repaired. `external` is http(s), excluded from the broken-links
/// screen entirely; `otherScheme` (`mailto:`, `obsidian:`) is shown, because a wrong one is worth
/// seeing. `unresolvable` means the note has no container, so there is nothing to resolve against.
public enum NoteLinkKind: String, Codable, Sendable, Equatable {
    case note, attachment, external, anchor, outside, broken, unresolvable
    case otherScheme = "other_scheme"
}

/// One link found in a note's body — either a wikilink or a markdown link.
public struct NoteLink: Codable, Sendable, Equatable, Hashable {
    /// Position in document order. Stable for as long as the body is.
    public let ordinal: Int
    public let syntax: String
    public let isEmbed: Bool
    /// Exactly as written in the body, before alias and anchor were split off.
    public let rawTarget: String
    /// Percent-decoded, `./`-stripped and `.md`-stripped.
    public let pathTarget: String
    public let anchor: String?
    public let alias: String?
    public let kind: NoteLinkKind
    public let targetNoteId: String?
    public let targetNoteName: String?
    public let targetAttachmentPath: String?

    public init(
        ordinal: Int, syntax: String, isEmbed: Bool, rawTarget: String, pathTarget: String,
        anchor: String?, alias: String?, kind: NoteLinkKind, targetNoteId: String?,
        targetNoteName: String?, targetAttachmentPath: String?
    ) {
        self.ordinal = ordinal
        self.syntax = syntax
        self.isEmbed = isEmbed
        self.rawTarget = rawTarget
        self.pathTarget = pathTarget
        self.anchor = anchor
        self.alias = alias
        self.kind = kind
        self.targetNoteId = targetNoteId
        self.targetNoteName = targetNoteName
        self.targetAttachmentPath = targetAttachmentPath
    }

    enum CodingKeys: String, CodingKey {
        case ordinal, syntax, anchor, alias, kind
        case isEmbed = "is_embed"
        case rawTarget = "raw_target"
        case pathTarget = "path_target"
        case targetNoteId = "target_note_id"
        case targetNoteName = "target_note_name"
        case targetAttachmentPath = "target_attachment_path"
    }
}

/// A note pointing AT the note being asked about. Counted rather than listed per link, because a
/// delete confirmation wants the notes it would damage, not every individual mention.
public struct NoteBacklink: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let noteId: String
    public let noteName: String
    public let count: Int

    public var id: String { noteId }

    public init(noteId: String, noteName: String, count: Int) {
        self.noteId = noteId
        self.noteName = noteName
        self.count = count
    }

    enum CodingKeys: String, CodingKey {
        case count
        case noteId = "note_id"
        case noteName = "note_name"
    }
}

/// `GET /api/notes/{id}/links` — both directions in one call, because the panel shows both and a
/// second round trip on a phone is a visible delay.
public struct NoteLinkGraph: Codable, Sendable, Equatable {
    public let outgoing: [NoteLink]
    public let backlinks: [NoteBacklink]
    /// The body was too large to parse, so both lists UNDERSTATE. Say so in the UI: a delete
    /// confirmation that silently shows no backlinks reads as "nothing points here", which is the
    /// one wrong thing it could say.
    public let extractionSkipped: Bool

    public init(outgoing: [NoteLink], backlinks: [NoteBacklink], extractionSkipped: Bool) {
        self.outgoing = outgoing
        self.backlinks = backlinks
        self.extractionSkipped = extractionSkipped
    }

    enum CodingKeys: String, CodingKey {
        case outgoing, backlinks
        case extractionSkipped = "extraction_skipped"
    }
}

/// One link on the broken-links screen, named from the note that wrote it.
public struct NoteLinkIssue: Codable, Sendable, Equatable, Hashable {
    public let sourceNoteId: String
    public let sourceNoteName: String
    public let ordinal: Int
    public let rawTarget: String
    public let kind: NoteLinkKind

    public init(sourceNoteId: String, sourceNoteName: String, ordinal: Int, rawTarget: String, kind: NoteLinkKind) {
        self.sourceNoteId = sourceNoteId
        self.sourceNoteName = sourceNoteName
        self.ordinal = ordinal
        self.rawTarget = rawTarget
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case ordinal, kind
        case sourceNoteId = "source_note_id"
        case sourceNoteName = "source_note_name"
        case rawTarget = "raw_target"
    }
}

/// `GET /api/notes/containers/{id}/link-health` — the whole broken-links screen in one answer.
/// Nothing here is ever acted on automatically; every list is a view and every removal is a
/// per-row action somebody takes.
public struct NoteLinkHealth: Codable, Sendable, Equatable {
    /// Resolves to nothing and was not written as a deliberate escape.
    public let broken: [NoteLinkIssue]
    /// Deliberately reaches outside the container. Shown, never repaired.
    public let outside: [NoteLinkIssue]
    public let unlinkedAttachments: [NoteAttachmentRecord]
    public let unlinkedNotes: [NoteSummary]
    /// Names shared by more than one note in the container. Resolution picks one of them, so an
    /// ambiguous name makes the resolved count look better than it is.
    public let ambiguousNames: [String]

    public init(
        broken: [NoteLinkIssue], outside: [NoteLinkIssue], unlinkedAttachments: [NoteAttachmentRecord],
        unlinkedNotes: [NoteSummary], ambiguousNames: [String]
    ) {
        self.broken = broken
        self.outside = outside
        self.unlinkedAttachments = unlinkedAttachments
        self.unlinkedNotes = unlinkedNotes
        self.ambiguousNames = ambiguousNames
    }

    enum CodingKeys: String, CodingKey {
        case broken, outside
        case unlinkedAttachments = "unlinked_attachments"
        case unlinkedNotes = "unlinked_notes"
        case ambiguousNames = "ambiguous_names"
    }
}

/// Previous versions COALESCE server-side: a new one only opens once the newest is some minutes
/// old, so an editing session leaves checkpoints rather than one row per keystroke.
public struct NoteRevisionSummary: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let createdAtMs: Int
    /// Which side wrote the version that REPLACED this one — `"ui"`, `"disk"`, `"mcp"`,
    /// `"rename"`, `"restore"`, kept a `String` for the same open-vocabulary reason
    /// `NoteDetail.lastWriteSource` is.
    public let source: String
    public let contentHash: String
    public let sizeBytes: Int

    public init(id: String, createdAtMs: Int, source: String, contentHash: String, sizeBytes: Int) {
        self.id = id
        self.createdAtMs = createdAtMs
        self.source = source
        self.contentHash = contentHash
        self.sizeBytes = sizeBytes
    }

    enum CodingKeys: String, CodingKey {
        case id, source
        case createdAtMs = "created_at_ms"
        case contentHash = "content_hash"
        case sizeBytes = "size_bytes"
    }
}

public struct NoteRevisionDetail: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let createdAtMs: Int
    public let source: String
    public let contentHash: String
    public let sizeBytes: Int
    public let frontmatter: String?
    public let body: String

    public init(
        id: String, createdAtMs: Int, source: String, contentHash: String, sizeBytes: Int,
        frontmatter: String?, body: String
    ) {
        self.id = id
        self.createdAtMs = createdAtMs
        self.source = source
        self.contentHash = contentHash
        self.sizeBytes = sizeBytes
        self.frontmatter = frontmatter
        self.body = body
    }

    enum CodingKeys: String, CodingKey {
        case id, source, frontmatter, body
        case createdAtMs = "created_at_ms"
        case contentHash = "content_hash"
        case sizeBytes = "size_bytes"
    }
}

/// A full-text hit. Offsets are character positions so the extract can be highlighted
/// client-side rather than shipping rendered markup.
public struct NoteSearchHit: Codable, Sendable, Equatable, Identifiable {
    public let note: NoteSummary
    public var id: String { note.id }
    /// Total matches in the body, which may exceed what `extract` shows.
    public let matchCount: Int
    public let extract: String
    /// Start offsets of each match WITHIN `extract`.
    public let extractOffsets: [Int]

    public init(note: NoteSummary, matchCount: Int, extract: String, extractOffsets: [Int]) {
        self.note = note
        self.matchCount = matchCount
        self.extract = extract
        self.extractOffsets = extractOffsets
    }

    enum CodingKeys: String, CodingKey {
        case note, extract
        case matchCount = "match_count"
        case extractOffsets = "extract_offsets"
    }
}

/// `GET /api/notes/search` — literal substring matching, not stemmed full-text search: finding
/// part of an identifier or a path is exactly what this is for, and a tokeniser would drop those.
public struct NoteSearchPage: Codable, Sendable, Equatable {
    public let hits: [NoteSearchHit]
    /// The result cap was reached; there are more matches than are shown.
    public let truncated: Bool

    public init(hits: [NoteSearchHit], truncated: Bool) {
        self.hits = hits
        self.truncated = truncated
    }
}

/// One hit from a semantic search scoped to notes — `POST /api/memory/search` filtered to
/// `type: "note"`. The generic route answers an open `metadata` dictionary; the only key notes
/// ever write into it is `note_id` (`embed_note`'s job handler, backend-side), so this reads out
/// just that one and lets a hit missing it fail the whole decode — which would mean the `type`
/// filter itself stopped working, not something to paper over.
public struct NoteSemanticHit: Sendable, Equatable, Identifiable {
    public let noteId: String
    /// Cosine similarity, 0-1 — closer to 1 is a better match.
    public let score: Double

    public var id: String { noteId }

    public init(noteId: String, score: Double) {
        self.noteId = noteId
        self.score = score
    }
}

extension NoteSemanticHit: Decodable {
    private enum CodingKeys: String, CodingKey { case score, metadata }
    private enum MetadataKeys: String, CodingKey { case noteId = "note_id" }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        score = try container.decode(Double.self, forKey: .score)
        let metadata = try container.nestedContainer(keyedBy: MetadataKeys.self, forKey: .metadata)
        noteId = try metadata.decode(String.self, forKey: .noteId)
    }
}
