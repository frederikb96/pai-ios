import Foundation

/// Swift port of `pai-cloud/web/src/api/types.ts` ("Shared notes", owner side). A note is shared
/// by link — at most one read-only and one editable link — and visitors reach it on a separate
/// public origin this app never talks to. The owner manages links and the attachment sandbox
/// through `/api/notes/{id}/share/*`; nothing moves between the sandbox and the vault without one
/// of those owner calls.

/// `read` or `edit`. A closed set by contract — the backend refuses any other kind — so unlike
/// the open enums elsewhere in this port it has no `unrecognized` case.
public enum NoteShareKind: String, Codable, Sendable, Hashable, CaseIterable {
    case read, edit

    /// What the owner sees the link called.
    public var label: String {
        switch self {
        case .read: return "Read-only link"
        case .edit: return "Editable link"
        }
    }
}

/// Where a sandbox file came from: `vault` was published by the owner, `public` was uploaded by a
/// link holder and is waiting to be accepted.
public enum NoteShareBlobOrigin: Sendable, Hashable {
    case vault, `public`
    case unrecognized(String)
}

extension NoteShareBlobOrigin: Codable {
    private static let knownValues: [String: NoteShareBlobOrigin] = ["vault": .vault, "public": .public]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownValues[raw] ?? .unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .vault: try container.encode("vault")
        case .public: try container.encode("public")
        case let .unrecognized(raw): try container.encode(raw)
        }
    }
}

/// Size ceilings, published so a client checks before sending rather than carrying its own copy
/// of each number. Bytes throughout.
public struct NoteShareLimits: Codable, Sendable, Equatable {
    public let bodyMaxBytes: Int
    public let uploadMaxBytes: Int
    public let sandboxMaxBytes: Int
    public let sandboxMaxFiles: Int
    /// Largest vault file that can be published into the sandbox.
    public let publishMaxBytes: Int

    public init(
        bodyMaxBytes: Int, uploadMaxBytes: Int, sandboxMaxBytes: Int, sandboxMaxFiles: Int, publishMaxBytes: Int
    ) {
        self.bodyMaxBytes = bodyMaxBytes
        self.uploadMaxBytes = uploadMaxBytes
        self.sandboxMaxBytes = sandboxMaxBytes
        self.sandboxMaxFiles = sandboxMaxFiles
        self.publishMaxBytes = publishMaxBytes
    }

    enum CodingKeys: String, CodingKey {
        case bodyMaxBytes = "body_max_bytes"
        case uploadMaxBytes = "upload_max_bytes"
        case sandboxMaxBytes = "sandbox_max_bytes"
        case sandboxMaxFiles = "sandbox_max_files"
        case publishMaxBytes = "publish_max_bytes"
    }
}

public struct NoteShareLink: Codable, Sendable, Equatable {
    public let kind: NoteShareKind
    /// The full link to hand out, token in the fragment.
    public let url: String
    /// An edit link's address that opens straight in the editor instead of the reader; nil on a
    /// read link.
    public let editingUrl: String?
    public let createdAtMs: Int
    /// Legacy ids that redirect to this link (imported HedgeDoc notes).
    public let aliases: [String]

    public init(kind: NoteShareKind, url: String, editingUrl: String? = nil, createdAtMs: Int, aliases: [String] = []) {
        self.kind = kind
        self.url = url
        self.editingUrl = editingUrl
        self.createdAtMs = createdAtMs
        self.aliases = aliases
    }

    /// The address to hand out: the editing one when asked for and this link has one.
    public func address(opensEditing: Bool) -> String {
        opensEditing ? editingUrl ?? url : url
    }

    enum CodingKeys: String, CodingKey {
        case kind, url, aliases
        case editingUrl = "editing_url"
        case createdAtMs = "created_at_ms"
    }
}

/// One file in the sandbox. Bytes are fetched separately, by `id`.
public struct NoteShareBlob: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// Container-root-relative path a body link resolves against (`attachments/x.png`): where a
    /// published file lives in the vault, or where an upload will land once accepted.
    public let relPath: String
    public let sizeBytes: Int
    public let contentType: String
    public let origin: NoteShareBlobOrigin
    public let createdAtMs: Int

    public init(
        id: String, name: String, relPath: String, sizeBytes: Int, contentType: String,
        origin: NoteShareBlobOrigin, createdAtMs: Int
    ) {
        self.id = id
        self.name = name
        self.relPath = relPath
        self.sizeBytes = sizeBytes
        self.contentType = contentType
        self.origin = origin
        self.createdAtMs = createdAtMs
    }

    /// Raster images the queue may draw before the owner decides. SVG is deliberately absent — it
    /// is a document that can carry script — and so is anything else a visitor could upload.
    public static let previewableContentTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    /// Above this a preview is skipped: decoding a visitor's 50 MB upload only to draw a thumbnail
    /// is a cost nobody asked for, and the owner can still accept or discard it by name.
    public static let maxPreviewBytes = 10 * 1024 * 1024

    public var isPreviewableImage: Bool {
        Self.previewableContentTypes.contains(contentType.lowercased()) && sizeBytes <= Self.maxPreviewBytes
    }

    enum CodingKeys: String, CodingKey {
        case id, name, origin
        case relPath = "rel_path"
        case sizeBytes = "size_bytes"
        case contentType = "content_type"
        case createdAtMs = "created_at_ms"
    }
}

/// A vault file the note links to that visitors cannot see yet — derived on every read, never
/// stored. `reason` is `new` (not in the sandbox) or `changed` (the vault file differs from the
/// published copy).
public struct NoteShareOutgoing: Codable, Sendable, Equatable, Identifiable {
    public var id: String { relPath }
    public let relPath: String
    public let name: String
    public let sizeBytes: Int
    public let mtimeMs: Int
    public let reason: String
    /// A visitor's edit introduced this link. Never part of "publish all" — naming a file in the
    /// body is not a reason to expose it.
    public let requestedByVisitor: Bool
    /// Above `NoteShareLimits.publishMaxBytes`; cannot be published.
    public let tooLarge: Bool

    public init(
        relPath: String, name: String, sizeBytes: Int, mtimeMs: Int, reason: String,
        requestedByVisitor: Bool, tooLarge: Bool
    ) {
        self.relPath = relPath
        self.name = name
        self.sizeBytes = sizeBytes
        self.mtimeMs = mtimeMs
        self.reason = reason
        self.requestedByVisitor = requestedByVisitor
        self.tooLarge = tooLarge
    }

    enum CodingKeys: String, CodingKey {
        case name, reason
        case relPath = "rel_path"
        case sizeBytes = "size_bytes"
        case mtimeMs = "mtime_ms"
        case requestedByVisitor = "requested_by_visitor"
        case tooLarge = "too_large"
    }
}

/// `GET /api/notes/{id}/share`.
public struct NoteShare: Codable, Sendable, Equatable {
    public struct Links: Codable, Sendable, Equatable {
        public let read: NoteShareLink?
        public let edit: NoteShareLink?

        public init(read: NoteShareLink? = nil, edit: NoteShareLink? = nil) {
            self.read = read
            self.edit = edit
        }

        public subscript(kind: NoteShareKind) -> NoteShareLink? {
            switch kind {
            case .read: return read
            case .edit: return edit
            }
        }
    }

    public let noteId: String
    public let links: Links
    /// Open tabs on this note right now, owner and visitors together.
    public let viewers: Int
    /// Waiting for the owner to publish.
    public let outgoing: [NoteShareOutgoing]
    /// Visitor uploads waiting for the owner to accept or discard.
    public let incoming: [NoteShareBlob]
    /// Everything visitors can currently see, both origins.
    public let sandbox: [NoteShareBlob]
    public let sandboxBytes: Int
    public let limits: NoteShareLimits

    public init(
        noteId: String, links: Links, viewers: Int, outgoing: [NoteShareOutgoing], incoming: [NoteShareBlob],
        sandbox: [NoteShareBlob], sandboxBytes: Int, limits: NoteShareLimits
    ) {
        self.noteId = noteId
        self.links = links
        self.viewers = viewers
        self.outgoing = outgoing
        self.incoming = incoming
        self.sandbox = sandbox
        self.sandboxBytes = sandboxBytes
        self.limits = limits
    }

    enum CodingKeys: String, CodingKey {
        case links, viewers, outgoing, incoming, sandbox, limits
        case noteId = "note_id"
        case sandboxBytes = "sandbox_bytes"
    }
}

/// `DELETE /api/notes/{id}/share/{kind}`. Deleting the last link drops the whole sandbox, so
/// `discardedUploads` is what the owner never accepted.
public struct NoteShareDeleted: Codable, Sendable, Equatable {
    public let deleted: Bool
    public let sandboxDropped: Bool
    public let discardedUploads: Int

    public init(deleted: Bool, sandboxDropped: Bool, discardedUploads: Int) {
        self.deleted = deleted
        self.sandboxDropped = sandboxDropped
        self.discardedUploads = discardedUploads
    }

    enum CodingKeys: String, CodingKey {
        case deleted
        case sandboxDropped = "sandbox_dropped"
        case discardedUploads = "discarded_uploads"
    }
}

/// One item of a publish / accept / discard batch. `key` is the `rel_path` (publish) or the blob
/// `id` (accept, discard) it answers for.
public struct NoteShareItemResult: Codable, Sendable, Equatable {
    public let key: String
    public let ok: Bool
    public let error: String?
    public let blob: NoteShareBlob?

    public init(key: String, ok: Bool, error: String? = nil, blob: NoteShareBlob? = nil) {
        self.key = key
        self.ok = ok
        self.error = error
        self.blob = blob
    }
}

public struct NoteShareItemResults: Codable, Sendable, Equatable {
    public let results: [NoteShareItemResult]

    public init(results: [NoteShareItemResult]) {
        self.results = results
    }
}

/// `GET /api/notes/{id}/state?client_id=` — the owner editor's cheap poll, which also counts the
/// tab as a viewer.
public struct NoteState: Codable, Sendable, Equatable {
    public let contentHash: String
    public let viewers: Int

    public init(contentHash: String, viewers: Int) {
        self.contentHash = contentHash
        self.viewers = viewers
    }

    enum CodingKeys: String, CodingKey {
        case viewers
        case contentHash = "content_hash"
    }
}
