import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// Where ``OutboxStore`` persists — entries survive a reload or an app kill by construction,
/// exactly like ``DraftStore``'s own `localPersistence`, but a JSON array plus a directory of raw
/// blobs rather than one `UserDefaults` value: an inline file's bytes can be megabytes, which
/// `UserDefaults`/`SettingsKeyValueStore` is the wrong home for.
public protocol OutboxStorage: Sendable {
    func loadEntries() -> [OutboxEntry]
    func saveEntries(_ entries: [OutboxEntry])
    func writeInlineFile(_ data: Data, localId: String)
    func readInlineFile(localId: String) -> Data?
    func removeInlineFiles(localIds: [String])
}

/// Pure `Foundation` plus the one POSIX call neither `Foundation` nor `FileManager` guarantees —
/// `rename(2)`, atomic on the same volume — matching `LedgerFile`'s own discipline: a fresh temp
/// file, written whole, renamed over the real path, so a kill mid-write leaves the previous
/// snapshot intact rather than a half-written index.
public struct FileOutboxStorage: OutboxStorage {
    private let rootURL: URL

    /// `FileManager` is not `Sendable` on Apple's SDK, so holding one as a stored property makes
    /// this type unsendable there while compiling cleanly against Linux Foundation — an error
    /// only a macOS build sees. Reach for `.default` at each call site instead.
    private var fileManager: FileManager { .default }

    public init(rootURL: URL) {
        self.rootURL = rootURL
        try? fileManager.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
    }

    private var indexURL: URL { rootURL.appendingPathComponent("outbox.json") }
    private var filesDirectory: URL { rootURL.appendingPathComponent("files", isDirectory: true) }

    public func loadEntries() -> [OutboxEntry] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([OutboxEntry].self, from: data)) ?? []
    }

    public func saveEntries(_ entries: [OutboxEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let tempURL = rootURL.appendingPathComponent(".outbox.json.tmp-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: tempURL.path, contents: data) else { return }
        if rename(tempURL.path, indexURL.path) != 0 {
            try? fileManager.removeItem(at: tempURL)
        }
    }

    public func writeInlineFile(_ data: Data, localId: String) {
        try? data.write(to: filesDirectory.appendingPathComponent(localId), options: .atomic)
    }

    public func readInlineFile(localId: String) -> Data? {
        try? Data(contentsOf: filesDirectory.appendingPathComponent(localId))
    }

    public func removeInlineFiles(localIds: [String]) {
        for localId in localIds {
            try? fileManager.removeItem(at: filesDirectory.appendingPathComponent(localId))
        }
    }
}

/// A test double kept entirely in memory — no disk at all, for a test that only cares about
/// `OutboxStore`'s own scheduling and retry logic.
public final class OutboxInMemoryStorage: OutboxStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [OutboxEntry] = []
    private var files: [String: Data] = [:]

    public init() {}

    public func loadEntries() -> [OutboxEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public func saveEntries(_ entries: [OutboxEntry]) {
        lock.lock()
        self.entries = entries
        lock.unlock()
    }

    public func writeInlineFile(_ data: Data, localId: String) {
        lock.lock()
        files[localId] = data
        lock.unlock()
    }

    public func readInlineFile(localId: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return files[localId]
    }

    public func removeInlineFiles(localIds: [String]) {
        lock.lock()
        for id in localIds { files[id] = nil }
        lock.unlock()
    }
}
