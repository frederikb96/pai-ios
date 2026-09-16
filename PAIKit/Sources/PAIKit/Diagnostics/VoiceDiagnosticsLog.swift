import Foundation

/// A bounded, on-disk diagnostics log for the voice pipeline — present in every build, not only
/// debug ones, because the only device that ever misbehaves is the one running a release build
/// nobody can attach a debugger to.
///
/// Two halves, deliberately split: ``log(_:_:_:at:)`` only ever takes a lock and appends to an
/// in-memory array — cheap and bounded, so it is safe to call from any thread, including one that
/// must not block (an audio callback, a socket delegate queue). ``flush()`` does the actual file
/// I/O and is never called from `log(...)` itself; a caller schedules it periodically, and
/// ``exportData()``/``totalSizeBytes()`` call it inline since those are already on a path that can
/// block.
///
/// Rotation keeps the whole thing bounded: `limits.maxCurrentFileBytes` per file,
/// `limits.maxRetainedFiles` files kept — the oldest is dropped, never grown without limit. A
/// crash mid-write costs at most the last unflushed batch and, at worst, a truncated final line;
/// every earlier line is untouched, because this only ever appends.
public final class VoiceDiagnosticsLog: @unchecked Sendable {

    public struct Limits: Sendable, Equatable {
        public let maxCurrentFileBytes: Int
        public let maxRetainedFiles: Int

        public init(maxCurrentFileBytes: Int = 1_000_000, maxRetainedFiles: Int = 3) {
            self.maxCurrentFileBytes = maxCurrentFileBytes
            self.maxRetainedFiles = maxRetainedFiles
        }
    }

    private let directory: URL
    private let limits: Limits
    private let fileManager: FileManager

    private let lock = NSLock()
    private var pending: [VoiceLogEntry] = []

    public init(directory: URL, limits: Limits = Limits(), fileManager: FileManager = .default) {
        self.directory = directory
        self.limits = limits
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Redacts, then appends to the in-memory buffer under a lock — no I/O, safe from any thread.
    public func log(_ level: VoiceLogLevel, _ category: String, _ message: String, at date: Date = Date()) {
        let entry = VoiceLogEntry(
            at: date, level: level, category: category, message: VoiceCredentialRedaction.redact(message))
        lock.lock()
        pending.append(entry)
        lock.unlock()
    }

    public func log(_ level: VoiceLogLevel, _ category: VoiceLogCategory, _ message: String, at date: Date = Date()) {
        log(level, category.rawValue, message, at: date)
    }

    /// Writes every pending entry to disk, rotating the current file once appending would push it
    /// past `limits.maxCurrentFileBytes`. Does real, blocking file I/O — call from a background
    /// task or a place that can already block, never from inside an audio callback.
    public func flush() {
        let toWrite: [VoiceLogEntry]
        lock.lock()
        toWrite = pending
        pending.removeAll()
        lock.unlock()
        guard !toWrite.isEmpty else { return }

        if !fileManager.fileExists(atPath: currentURL.path) {
            fileManager.createFile(atPath: currentURL.path, contents: nil)
        }
        var currentSize = fileSize(currentURL)

        let formatter = Self.makeFormatter()
        for entry in toWrite {
            let lineData = Data((Self.formatLine(entry, formatter: formatter) + "\n").utf8)
            if currentSize > 0, currentSize + lineData.count > limits.maxCurrentFileBytes {
                rotate()
                fileManager.createFile(atPath: currentURL.path, contents: nil)
                currentSize = 0
            }
            appendToCurrentFile(lineData)
            currentSize += lineData.count
        }
    }

    /// Every retained line, oldest first, flushing whatever is still pending so a send/share right
    /// after an event still includes it.
    public func exportData() -> Data {
        flush()
        var combined = Data()
        for index in stride(from: limits.maxRetainedFiles - 1, through: 1, by: -1) {
            if let data = try? Data(contentsOf: rotatedURL(index)) { combined.append(data) }
        }
        if let data = try? Data(contentsOf: currentURL) { combined.append(data) }
        return combined
    }

    public func totalSizeBytes() -> Int {
        flush()
        var total = fileSize(currentURL)
        for index in 1..<limits.maxRetainedFiles {
            total += fileSize(rotatedURL(index))
        }
        return total
    }

    public func clear() {
        lock.lock()
        pending.removeAll()
        lock.unlock()
        try? fileManager.removeItem(at: currentURL)
        for index in 1..<limits.maxRetainedFiles {
            try? fileManager.removeItem(at: rotatedURL(index))
        }
    }

    // MARK: - Files

    private var currentURL: URL { directory.appendingPathComponent("voice-diagnostics.log") }
    private func rotatedURL(_ index: Int) -> URL { directory.appendingPathComponent("voice-diagnostics.\(index).log") }

    /// Shifts every rotated file up by one slot and drops whatever falls off the end, then moves
    /// the current file into slot 1 — the youngest rotated slot.
    private func rotate() {
        guard limits.maxRetainedFiles > 1 else {
            try? fileManager.removeItem(at: currentURL)
            return
        }
        let oldestIndex = limits.maxRetainedFiles - 1
        try? fileManager.removeItem(at: rotatedURL(oldestIndex))
        var index = oldestIndex
        while index > 1 {
            let from = rotatedURL(index - 1)
            if fileManager.fileExists(atPath: from.path) {
                try? fileManager.removeItem(at: rotatedURL(index))
                try? fileManager.moveItem(at: from, to: rotatedURL(index))
            }
            index -= 1
        }
        if fileManager.fileExists(atPath: currentURL.path) {
            try? fileManager.removeItem(at: rotatedURL(1))
            try? fileManager.moveItem(at: currentURL, to: rotatedURL(1))
        }
    }

    private func appendToCurrentFile(_ data: Data) {
        guard let handle = try? FileHandle(forWritingTo: currentURL) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func fileSize(_ url: URL) -> Int {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return 0 }
        return (attributes[.size] as? Int) ?? 0
    }

    // MARK: - Formatting

    private static func makeFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static func formatLine(_ entry: VoiceLogEntry, formatter: ISO8601DateFormatter) -> String {
        "\(formatter.string(from: entry.at)) [\(entry.level.rawValue)] \(entry.category): \(entry.message)"
    }
}
