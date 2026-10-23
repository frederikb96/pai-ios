import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// The note index as the last successful fetch returned it — the server's rows, without any
/// local overlay, so loading it back can never mistake an unsynced rename for the server's name.
public struct CachedNoteIndex: Codable, Sendable, Equatable {
    public let notes: [NoteSummary]
    public let fetchedAtMs: Int

    public init(notes: [NoteSummary], fetchedAtMs: Int) {
        self.notes = notes
        self.fetchedAtMs = fetchedAtMs
    }
}

/// One attachment kept on disk. `fileId` names the blob, so a container path never has to be
/// turned into a file name. `sizeBytes`/`mtimeMs` are the inventory's record at the time the
/// bytes were fetched — what decides later whether the server still holds the same file.
public struct CachedAttachment: Codable, Sendable, Equatable {
    public let fileId: String
    public let containerId: String
    public let path: String
    public let byteCount: Int
    public let sizeBytes: Int?
    public let mtimeMs: Int?
    public var lastUsedMs: Int

    public init(
        fileId: String, containerId: String, path: String, byteCount: Int, sizeBytes: Int?, mtimeMs: Int?,
        lastUsedMs: Int
    ) {
        self.fileId = fileId
        self.containerId = containerId
        self.path = path
        self.byteCount = byteCount
        self.sizeBytes = sizeBytes
        self.mtimeMs = mtimeMs
        self.lastUsedMs = lastUsedMs
    }

    /// Whether the inventory still describes the file these bytes came from. A copy fetched
    /// without an inventory record to compare against never matches, so it is fetched once more
    /// as soon as the inventory is known.
    public func matches(_ record: NoteAttachmentRecord) -> Bool {
        sizeBytes == record.sizeBytes && mtimeMs == record.mtimeMs
    }
}

/// Where the notes cache lives: everything here can be fetched again, so all of it may be
/// cleared, and none of it is the only copy of anything. Unsaved edits live in
/// ``NoteOutboxStorage`` instead, which nothing here can reach.
public protocol NotesCacheStorage: Sendable {
    func loadIndex() -> CachedNoteIndex?
    func saveIndex(_ index: CachedNoteIndex)

    func loadBody(noteId: String) -> NoteDetail?
    func saveBody(_ detail: NoteDetail)
    func removeBody(noteId: String)
    /// Every cached body's `updatedAtMs`, by note id — what the staleness pass compares against
    /// the index without decoding whole notes on the main actor.
    func bodyStamps() -> [String: Int]

    func loadInventory(containerId: String) -> [NoteAttachmentRecord]?
    func saveInventory(_ records: [NoteAttachmentRecord], containerId: String)

    func loadAttachmentManifest() -> [CachedAttachment]
    func saveAttachmentManifest(_ entries: [CachedAttachment])
    func readAttachment(fileId: String) -> Data?
    /// Whether the bytes reached disk. A failed write must not be recorded in the manifest.
    func writeAttachment(_ data: Data, fileId: String) -> Bool
    func removeAttachment(fileId: String)

    /// Bytes held by everything except attachment blobs: the index, bodies, inventories and the
    /// manifest itself. Counted toward the budget, never evicted by it.
    func metadataBytes() -> Int
    /// Removes everything this storage holds.
    func clear()
}

/// Files under one root directory. Every JSON file is written whole to a temp file and renamed
/// over the real path (`rename(2)` is atomic on one volume), so a kill mid-write leaves the
/// previous version rather than a truncated file; blobs use `.atomic`, which does the same.
public struct FileNotesCacheStorage: NotesCacheStorage {
    public let rootURL: URL

    /// `FileManager` is not `Sendable` on Apple's SDK; a stored one makes this type unsendable
    /// there while Linux compiles it cleanly.
    private var fileManager: FileManager { .default }

    public init(rootURL: URL) {
        self.rootURL = rootURL
        createDirectories()
    }

    private var indexURL: URL { rootURL.appendingPathComponent("index.json") }
    private var manifestURL: URL { rootURL.appendingPathComponent("attachments.json") }
    private var bodiesDirectory: URL { rootURL.appendingPathComponent("bodies", isDirectory: true) }
    private var inventoriesDirectory: URL { rootURL.appendingPathComponent("inventories", isDirectory: true) }
    private var attachmentsDirectory: URL { rootURL.appendingPathComponent("attachments", isDirectory: true) }

    private func createDirectories() {
        for directory in [bodiesDirectory, inventoriesDirectory, attachmentsDirectory] {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func bodyURL(_ noteId: String) -> URL {
        bodiesDirectory.appendingPathComponent(NotesFileName.safe(noteId) + ".json")
    }

    public func loadIndex() -> CachedNoteIndex? {
        NotesFileIO.read(CachedNoteIndex.self, from: indexURL)
    }

    public func saveIndex(_ index: CachedNoteIndex) {
        NotesFileIO.write(index, to: indexURL)
    }

    public func loadBody(noteId: String) -> NoteDetail? {
        NotesFileIO.read(NoteDetail.self, from: bodyURL(noteId))
    }

    public func saveBody(_ detail: NoteDetail) {
        NotesFileIO.write(detail, to: bodyURL(detail.id))
    }

    public func removeBody(noteId: String) {
        try? fileManager.removeItem(at: bodyURL(noteId))
    }

    public func bodyStamps() -> [String: Int] {
        struct Stamp: Decodable {
            let id: String
            let updatedAtMs: Int
            enum CodingKeys: String, CodingKey {
                case id
                case updatedAtMs = "updated_at_ms"
            }
        }
        let files = (try? fileManager.contentsOfDirectory(at: bodiesDirectory, includingPropertiesForKeys: nil)) ?? []
        var stamps: [String: Int] = [:]
        for file in files where file.pathExtension == "json" {
            if let stamp = NotesFileIO.read(Stamp.self, from: file) { stamps[stamp.id] = stamp.updatedAtMs }
        }
        return stamps
    }

    public func loadInventory(containerId: String) -> [NoteAttachmentRecord]? {
        NotesFileIO.read(
            [NoteAttachmentRecord].self,
            from: inventoriesDirectory.appendingPathComponent(NotesFileName.safe(containerId) + ".json"))
    }

    public func saveInventory(_ records: [NoteAttachmentRecord], containerId: String) {
        NotesFileIO.write(
            records, to: inventoriesDirectory.appendingPathComponent(NotesFileName.safe(containerId) + ".json"))
    }

    public func loadAttachmentManifest() -> [CachedAttachment] {
        NotesFileIO.read([CachedAttachment].self, from: manifestURL) ?? []
    }

    public func saveAttachmentManifest(_ entries: [CachedAttachment]) {
        NotesFileIO.write(entries, to: manifestURL)
    }

    public func readAttachment(fileId: String) -> Data? {
        try? Data(contentsOf: attachmentsDirectory.appendingPathComponent(NotesFileName.safe(fileId)))
    }

    public func writeAttachment(_ data: Data, fileId: String) -> Bool {
        do {
            try data.write(
                to: attachmentsDirectory.appendingPathComponent(NotesFileName.safe(fileId)), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public func removeAttachment(fileId: String) {
        try? fileManager.removeItem(at: attachmentsDirectory.appendingPathComponent(NotesFileName.safe(fileId)))
    }

    public func metadataBytes() -> Int {
        var total = NotesFileIO.size(of: indexURL) + NotesFileIO.size(of: manifestURL)
        for directory in [bodiesDirectory, inventoriesDirectory] {
            let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files { total += NotesFileIO.size(of: file) }
        }
        return total
    }

    public func clear() {
        let entries = (try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        for entry in entries { try? fileManager.removeItem(at: entry) }
        createDirectories()
    }
}

/// Note and container ids are UUIDs or short slugs today, but they arrive from the server, and a
/// `/` or `..` in one must never reach a path outside the directory it is meant for.
enum NotesFileName {
    static func safe(_ raw: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
        return encoded.isEmpty ? "_" : encoded
    }
}

/// The write discipline both note stores share: encode, write a fresh temp file beside the
/// target, rename it over the target.
enum NotesFileIO {
    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    static func write(_ value: some Encodable, to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        let directory = url.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tempURL.path, contents: data) else { return false }
        if rename(tempURL.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
        return true
    }

    static func size(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }
}

/// The notes cache kept in memory, for tests that exercise the store's rules rather than the
/// file system.
public final class InMemoryNotesCacheStorage: NotesCacheStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var index: CachedNoteIndex?
    private var bodies: [String: NoteDetail] = [:]
    private var inventories: [String: [NoteAttachmentRecord]] = [:]
    private var manifest: [CachedAttachment] = []
    private var blobs: [String: Data] = [:]

    public init() {}

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public func loadIndex() -> CachedNoteIndex? { locked { index } }
    public func saveIndex(_ index: CachedNoteIndex) { locked { self.index = index } }
    public func loadBody(noteId: String) -> NoteDetail? { locked { bodies[noteId] } }
    public func saveBody(_ detail: NoteDetail) { locked { bodies[detail.id] = detail } }
    public func removeBody(noteId: String) { locked { bodies[noteId] = nil } }
    public func bodyStamps() -> [String: Int] { locked { bodies.mapValues(\.updatedAtMs) } }
    public func loadInventory(containerId: String) -> [NoteAttachmentRecord]? { locked { inventories[containerId] } }
    public func saveInventory(_ records: [NoteAttachmentRecord], containerId: String) {
        locked { inventories[containerId] = records }
    }
    public func loadAttachmentManifest() -> [CachedAttachment] { locked { manifest } }
    public func saveAttachmentManifest(_ entries: [CachedAttachment]) { locked { manifest = entries } }
    public func readAttachment(fileId: String) -> Data? { locked { blobs[fileId] } }
    public func writeAttachment(_ data: Data, fileId: String) -> Bool {
        locked {
            blobs[fileId] = data
            return true
        }
    }
    public func removeAttachment(fileId: String) { locked { blobs[fileId] = nil } }
    public func metadataBytes() -> Int {
        locked {
            let encoder = JSONEncoder()
            var total = index.flatMap { try? encoder.encode($0).count } ?? 0
            for body in bodies.values { total += (try? encoder.encode(body).count) ?? 0 }
            return total
        }
    }
    public func clear() {
        locked {
            index = nil
            bodies = [:]
            inventories = [:]
            manifest = []
            blobs = [:]
        }
    }
}
