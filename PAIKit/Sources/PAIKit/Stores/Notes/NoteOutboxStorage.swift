import Foundation

/// A note's unsaved body, as it stands on screen, with the version it was typed over.
///
/// `base` is a whole ``NoteDetail`` rather than a hash so the record is self-contained: clearing
/// the cache, or a cache that never held the note, cannot leave an edit with nothing to say what
/// it was written against. A save is conditional on `base.contentHash`, so a base that is out of
/// date can only ever produce a conflict, never a silent overwrite.
public struct NotePendingEdit: Codable, Sendable, Equatable {
    public let noteId: String
    public var body: String
    public var base: NoteDetail
    public var editedAtMs: Int
    /// Conflicts met while syncing this edit.
    public var attempts: Int
    /// A conflict the reader was shown and has not answered. Kept so a relaunch asks again
    /// instead of settling the question by itself.
    public var raisedConflict: NoteConflict?
    /// Set when the edit could not reach the server (no network, a server error) — the edits the
    /// offline conflict policy applies to. An edit restored after the app was killed counts too.
    public var awaitingSync: Bool

    public init(
        noteId: String, body: String, base: NoteDetail, editedAtMs: Int, attempts: Int = 0,
        raisedConflict: NoteConflict? = nil, awaitingSync: Bool = false
    ) {
        self.noteId = noteId
        self.body = body
        self.base = base
        self.editedAtMs = editedAtMs
        self.attempts = attempts
        self.raisedConflict = raisedConflict
        self.awaitingSync = awaitingSync
    }
}

/// A rename or a favourite made without a connection: the latest value of each field, sent
/// without a hash when the network is back.
public struct NotePendingFieldPatch: Codable, Sendable, Equatable {
    public let noteId: String
    public var name: String?
    public var favourite: Bool?
    public var editedAtMs: Int

    public init(noteId: String, name: String? = nil, favourite: Bool? = nil, editedAtMs: Int) {
        self.noteId = noteId
        self.name = name
        self.favourite = favourite
        self.editedAtMs = editedAtMs
    }
}

/// Where unsaved note edits are kept until the server has them. Unlike the cache this holds the
/// only copy of what was typed, so nothing that clears or evicts the cache can reach it.
public protocol NoteOutboxStorage: Sendable {
    func loadEdits() -> [NotePendingEdit]
    func saveEdit(_ edit: NotePendingEdit)
    func removeEdit(noteId: String)
    func loadFieldPatches() -> [NotePendingFieldPatch]
    func saveFieldPatch(_ patch: NotePendingFieldPatch)
    func removeFieldPatch(noteId: String)
}

/// One JSON file per note under `edits/` and `fields/`, each replaced whole by an atomic rename,
/// so a kill mid-write leaves the previous version of that note's edit rather than none.
public struct FileNoteOutboxStorage: NoteOutboxStorage {
    public let rootURL: URL

    private var fileManager: FileManager { .default }

    public init(rootURL: URL) {
        self.rootURL = rootURL
        try? fileManager.createDirectory(at: editsDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: fieldsDirectory, withIntermediateDirectories: true)
    }

    private var editsDirectory: URL { rootURL.appendingPathComponent("edits", isDirectory: true) }
    private var fieldsDirectory: URL { rootURL.appendingPathComponent("fields", isDirectory: true) }

    private func url(in directory: URL, _ noteId: String) -> URL {
        directory.appendingPathComponent(NotesFileName.safe(noteId) + ".json")
    }

    private func loadAll<T: Decodable>(_ type: T.Type, in directory: URL) -> [T] {
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { NotesFileIO.read(T.self, from: $0) }
    }

    public func loadEdits() -> [NotePendingEdit] { loadAll(NotePendingEdit.self, in: editsDirectory) }

    public func saveEdit(_ edit: NotePendingEdit) {
        NotesFileIO.write(edit, to: url(in: editsDirectory, edit.noteId))
    }

    public func removeEdit(noteId: String) {
        try? fileManager.removeItem(at: url(in: editsDirectory, noteId))
    }

    public func loadFieldPatches() -> [NotePendingFieldPatch] {
        loadAll(NotePendingFieldPatch.self, in: fieldsDirectory)
    }

    public func saveFieldPatch(_ patch: NotePendingFieldPatch) {
        NotesFileIO.write(patch, to: url(in: fieldsDirectory, patch.noteId))
    }

    public func removeFieldPatch(noteId: String) {
        try? fileManager.removeItem(at: url(in: fieldsDirectory, noteId))
    }
}

/// Pending edits kept in memory, for tests of the store's rules. A test that needs to prove an
/// edit survives a restart builds a second store over the same instance.
public final class InMemoryNoteOutboxStorage: NoteOutboxStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var edits: [String: NotePendingEdit] = [:]
    private var patches: [String: NotePendingFieldPatch] = [:]

    public init() {}

    public func loadEdits() -> [NotePendingEdit] {
        lock.withLock { Array(edits.values) }
    }

    public func saveEdit(_ edit: NotePendingEdit) {
        lock.withLock { edits[edit.noteId] = edit }
    }

    public func removeEdit(noteId: String) {
        lock.withLock { edits[noteId] = nil }
    }

    public func loadFieldPatches() -> [NotePendingFieldPatch] {
        lock.withLock { Array(patches.values) }
    }

    public func saveFieldPatch(_ patch: NotePendingFieldPatch) {
        lock.withLock { patches[patch.noteId] = patch }
    }

    public func removeFieldPatch(noteId: String) {
        lock.withLock { patches[noteId] = nil }
    }
}
