import Foundation

/// A note's unsaved body, as it stands on screen, with the version it was typed over.
///
/// `base` is a whole ``NoteDetail`` rather than a hash so the record is self-contained: clearing
/// the cache, or a cache that never held the note, cannot leave an edit with nothing to say what
/// it was written against. A save is conditional on `base.contentHash`, so a base that is out of
/// date can only ever produce a conflict, never a silent overwrite.
///
/// Not `Codable` on purpose: on disk it is ``NotePendingEditRecordV1``, whose keys are written
/// out by hand, so a change to a wire model can never make a stored edit unreadable.
public struct NotePendingEdit: Sendable, Equatable {
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
    /// offline conflict policy applies to. An edit typed while the server was reachable and
    /// restored after the app was killed is not one: it is sent as an ordinary save.
    public var awaitingSync: Bool
    /// Waiting only because the server answered with an error while the network was up, never
    /// because there was no connection. Decides how the sync notice words it.
    public var waitedForServer: Bool
    /// The server refused this edit (the note was deleted elsewhere, or the request itself was
    /// rejected). Such an edit is not sent again by itself; the reader keeps or discards the text.
    public var refusal: String?

    public init(
        noteId: String, body: String, base: NoteDetail, editedAtMs: Int, attempts: Int = 0,
        raisedConflict: NoteConflict? = nil, awaitingSync: Bool = false, waitedForServer: Bool = false,
        refusal: String? = nil
    ) {
        self.noteId = noteId
        self.body = body
        self.base = base
        self.editedAtMs = editedAtMs
        self.attempts = attempts
        self.raisedConflict = raisedConflict
        self.awaitingSync = awaitingSync
        self.waitedForServer = waitedForServer
        self.refusal = refusal
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

    enum CodingKeys: String, CodingKey {
        case noteId, name, favourite, editedAtMs
    }

    /// Only the note id is required: a record missing anything else still says which note and
    /// what was asked for.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        noteId = try container.decode(String.self, forKey: .noteId)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        favourite = try container.decodeIfPresent(Bool.self, forKey: .favourite)
        editedAtMs = try container.decodeIfPresent(Int.self, forKey: .editedAtMs) ?? 0
    }
}

/// An outbox file this build could not read. It is moved aside rather than skipped, so the next
/// save of the same note cannot overwrite it, and whatever text it holds stays reachable.
public struct NoteQuarantinedEdit: Sendable, Equatable, Identifiable {
    /// The file's name in the quarantine folder.
    public let id: String
    /// The note it belonged to, when the file still says.
    public let noteId: String?
    /// The typed text when the file still holds it as a `body` (or, for a rename, the `name`);
    /// otherwise the file's raw contents.
    public let text: String

    public init(id: String, noteId: String?, text: String) {
        self.id = id
        self.noteId = noteId
        self.text = text
    }
}

/// Where unsaved note edits are kept until the server has them. Unlike the cache this holds the
/// only copy of what was typed, so nothing that clears or evicts the cache can reach it.
public protocol NoteOutboxStorage: Sendable {
    /// Every readable edit. A file that cannot be read is moved to quarantine on the way, never
    /// left where a save would replace it.
    func loadEdits() -> [NotePendingEdit]
    func saveEdit(_ edit: NotePendingEdit)
    func removeEdit(noteId: String)
    func loadFieldPatches() -> [NotePendingFieldPatch]
    func saveFieldPatch(_ patch: NotePendingFieldPatch)
    func removeFieldPatch(noteId: String)
    func loadQuarantined() -> [NoteQuarantinedEdit]
    func removeQuarantined(id: String)
}

/// One JSON file per note under `edits/` and `fields/`, each replaced whole by an atomic rename,
/// so a kill mid-write leaves the previous version of that note's edit rather than none. A file
/// that does not decode is moved to `unreadable/`.
public struct FileNoteOutboxStorage: NoteOutboxStorage {
    public let rootURL: URL

    private var fileManager: FileManager { .default }

    public init(rootURL: URL) {
        self.rootURL = rootURL
        for directory in [editsDirectory, fieldsDirectory, quarantineDirectory] {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private var editsDirectory: URL { rootURL.appendingPathComponent("edits", isDirectory: true) }
    private var fieldsDirectory: URL { rootURL.appendingPathComponent("fields", isDirectory: true) }
    private var quarantineDirectory: URL { rootURL.appendingPathComponent("unreadable", isDirectory: true) }

    private func url(in directory: URL, _ noteId: String) -> URL {
        directory.appendingPathComponent(NotesFileName.safe(noteId) + ".json")
    }

    private func files(in directory: URL) -> [URL] {
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
    }

    /// Decodes every file in `directory`; one that does not decode is moved to quarantine under
    /// `prefix` plus its own name, so an edit and a rename of the same note cannot collide there.
    private func loadAll<T>(in directory: URL, prefix: String, _ decode: (Data) throws -> T) -> [T] {
        var loaded: [T] = []
        for file in files(in: directory) {
            guard let data = try? Data(contentsOf: file) else { continue }
            if let value = try? decode(data) {
                loaded.append(value)
            } else {
                quarantine(file, as: prefix + file.lastPathComponent)
            }
        }
        return loaded
    }

    private func quarantine(_ file: URL, as name: String) {
        var target = quarantineDirectory.appendingPathComponent(name)
        if fileManager.fileExists(atPath: target.path) {
            target = quarantineDirectory.appendingPathComponent(
                target.deletingPathExtension().lastPathComponent + "-\(UUID().uuidString).json")
        }
        try? fileManager.moveItem(at: file, to: target)
    }

    public func loadEdits() -> [NotePendingEdit] {
        loadAll(in: editsDirectory, prefix: "edit-") { try NotePendingEditRecordV1.decode($0) }
    }

    public func saveEdit(_ edit: NotePendingEdit) {
        NotesFileIO.write(NotePendingEditRecordV1(edit), to: url(in: editsDirectory, edit.noteId))
    }

    public func removeEdit(noteId: String) {
        try? fileManager.removeItem(at: url(in: editsDirectory, noteId))
    }

    public func loadFieldPatches() -> [NotePendingFieldPatch] {
        loadAll(in: fieldsDirectory, prefix: "fields-") {
            try JSONDecoder().decode(NotePendingFieldPatch.self, from: $0)
        }
    }

    public func saveFieldPatch(_ patch: NotePendingFieldPatch) {
        NotesFileIO.write(patch, to: url(in: fieldsDirectory, patch.noteId))
    }

    public func removeFieldPatch(noteId: String) {
        try? fileManager.removeItem(at: url(in: fieldsDirectory, noteId))
    }

    public func loadQuarantined() -> [NoteQuarantinedEdit] {
        files(in: quarantineDirectory).sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { file in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return NoteQuarantinedEdit.reading(data, id: file.lastPathComponent)
        }
    }

    public func removeQuarantined(id: String) {
        let file = quarantineDirectory.appendingPathComponent(id)
        guard file.deletingLastPathComponent().standardizedFileURL == quarantineDirectory.standardizedFileURL else {
            return
        }
        try? fileManager.removeItem(at: file)
    }
}

extension NoteQuarantinedEdit {
    /// Whatever text a file the record decoder refused still holds: its `body`, a rename's
    /// `name`, or failing both the bytes as text.
    static func reading(_ data: Data, id: String) -> NoteQuarantinedEdit {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let text = object?["body"] as? String ?? object?["name"] as? String ?? String(decoding: data, as: UTF8.self)
        return NoteQuarantinedEdit(id: id, noteId: object?["noteId"] as? String, text: text)
    }
}

/// Pending edits kept in memory, for tests of the store's rules. A test that needs to prove an
/// edit survives a restart builds a second store over the same instance.
public final class InMemoryNoteOutboxStorage: NoteOutboxStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var edits: [String: NotePendingEdit] = [:]
    private var patches: [String: NotePendingFieldPatch] = [:]
    private var quarantined: [NoteQuarantinedEdit] = []
    /// How many edit writes reached this storage, for tests of how often the store writes.
    public private(set) var editWrites = 0

    public init(quarantined: [NoteQuarantinedEdit] = []) {
        self.quarantined = quarantined
    }

    public func loadEdits() -> [NotePendingEdit] {
        lock.withLock { Array(edits.values) }
    }

    public func saveEdit(_ edit: NotePendingEdit) {
        lock.withLock {
            edits[edit.noteId] = edit
            editWrites += 1
        }
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

    public func loadQuarantined() -> [NoteQuarantinedEdit] {
        lock.withLock { quarantined }
    }

    public func removeQuarantined(id: String) {
        lock.withLock { quarantined.removeAll { $0.id == id } }
    }
}
