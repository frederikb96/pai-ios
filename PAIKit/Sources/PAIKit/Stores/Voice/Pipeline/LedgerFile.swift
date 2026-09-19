import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// Reads and writes a `TranscriptLedger` to disk. Pure `Foundation` plus the one POSIX call
/// neither `Foundation` nor `FileManager` exposes a guarantee for — `rename(2)`, atomic on the
/// same volume — so this is provable on Linux exactly like `StreamingRecordingFile`.
///
/// Every write goes through a temp file, fsync'd, then renamed over the real path: the take's
/// audio is always written before the segment it produced is handed here (the recorder's
/// own write order), so a kill between the two leaves the ledger *behind* the audio — recovery
/// reads that gap as more-captured-than-covered, which is the safe direction, never a repair step
/// that has to guess. A kill mid-rename cannot happen: `rename(2)` either lands or it does not,
/// there is no partial state on disk for either outcome.
public enum LedgerFile {
    public enum WriteError: Error, Sendable, Equatable {
        case couldNotCreateTempFile
        case couldNotRename
    }

    /// Writes the ledger atomically: a fresh temp file beside `url`, `fsync`'d, then renamed over
    /// the destination. On any failure the destination is left exactly as it was — the temp file
    /// this attempt created is cleaned up, never left to be mistaken for a real ledger.
    public static func write(_ ledger: TranscriptLedger, to url: URL, fileManager: FileManager = .default) throws {
        let data = try JSONEncoder().encode(ledger)
        let tempURL =
            url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: tempURL.path, contents: data) else {
            throw WriteError.couldNotCreateTempFile
        }
        if let handle = try? FileHandle(forWritingTo: tempURL) {
            try? handle.synchronize()
            try? handle.close()
        }
        guard rename(tempURL.path, url.path) == 0 else {
            try? fileManager.removeItem(at: tempURL)
            throw WriteError.couldNotRename
        }
    }

    /// `nil` for anything that is not a decodable ledger — no file yet, a take with no ledger at
    /// all, or one a kill caught mid-*creation* of the very first temp file (impossible to
    /// observe from here as anything but "no ledger", since `rename` never ran).
    public static func read(from url: URL) -> TranscriptLedger? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TranscriptLedger.self, from: data)
    }
}
