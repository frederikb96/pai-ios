import Foundation
import PAIKit

/// Where a recording's bytes actually live on disk — the concrete half of `RecordingAudioStorage`
/// the package deliberately leaves out, since *where* on a sandboxed device is a real-device
/// concept a Linux toolchain cannot exercise (`RecordingsStore.swift`'s own doc comment).
///
/// One WAV file per (id, kind) under Application Support rather than Documents: these are app
/// data Freddy is not meant to browse in the Files app, the same way the web keeps them in
/// IndexedDB rather than a downloads folder.
struct FileRecordingAudioStorage: RecordingAudioStorage {
    private let directory: URL

    init(fileManager: FileManager = .default) {
        let base =
            (try? fileManager.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )) ?? fileManager.temporaryDirectory
        directory = base.appendingPathComponent("Recordings", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // A deliberate answer, not an accidental default: unlike a note or a draft, a recording
        // has no server copy at all (`RecordingAudioLibrary`'s own doc comment — "past recordings
        // are strictly client-local"), so device backup is the only redundancy this data ever
        // gets. For exactly Freddy's stated fear — losing an hour of dictation to a crash or a
        // dead phone — an iCloud/iTunes backup restoring these files is a second safety net, not
        // a leak to plug. Left included on purpose; see `StagedAttachmentStore` for the matching
        // decision on staged attachments, which answers the same question the same way.
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = false
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(resource)
    }

    func save(id: String, raw: Data?, sent: Data) async throws {
        try sent.write(to: sentURL(id: id), options: .atomic)
        if let raw {
            try raw.write(to: rawURL(id: id), options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: rawURL(id: id))
        }
    }

    func delete(id: String) async {
        try? FileManager.default.removeItem(at: sentURL(id: id))
        try? FileManager.default.removeItem(at: rawURL(id: id))
    }

    /// Not part of `RecordingAudioStorage` — that protocol only ever saves or deletes, since
    /// `RecordingsStore` itself never re-reads a recording's bytes. Reading is the recordings
    /// sheet's own concern (re-transcribe, attach), so it reaches this concrete type directly.
    func load(id: String) -> (raw: Data?, sent: Data)? {
        guard let sent = try? Data(contentsOf: sentURL(id: id)) else { return nil }
        let raw = try? Data(contentsOf: rawURL(id: id))
        return (raw, sent)
    }

    /// Where a take-in-progress should stream its bytes to, so a `StreamingRecordingFile` opened
    /// here already lives at the exact path `save(id:...)` would otherwise have written in one
    /// shot at the end — `VoiceRecorderController` reaches this directly, the same way `load`
    /// does, since `RecordingAudioStorage` is deliberately only ever a save-or-delete contract.
    func sentURL(id: String) -> URL { directory.appendingPathComponent("\(id)-sent.wav") }
    func rawURL(id: String) -> URL { directory.appendingPathComponent("\(id)-raw.wav") }

    /// The raw half alone, for when a take's raw budget was exceeded (or the raw stream never
    /// produced anything) but the sent half is still worth keeping — mirrors what `save(raw: nil)`
    /// already did for the non-streaming path.
    func removeRaw(id: String) {
        try? FileManager.default.removeItem(at: rawURL(id: id))
    }

    // MARK: - Startup reconciliation
    //
    // Nothing above this point ever looks at what is actually in `directory` — every other
    // method reaches a file by an id it already has. This is the one place that goes looking,
    // for `VoiceRecorderController.reconcileOrphanedRecordings()`.

    /// Every take id with sent audio on disk, parsed straight out of filenames —
    /// `RecordingMeta.id(forTimestampMs:)` is what named them, so this is the exact inverse.
    func idsOnDisk() -> Set<String> {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        let suffix = "-sent.wav"
        var ids = Set<String>()
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasSuffix(suffix) else { continue }
            ids.insert(String(name.dropLast(suffix.count)))
        }
        return ids
    }

    func hasRaw(id: String) -> Bool {
        FileManager.default.fileExists(atPath: rawURL(id: id).path)
    }

    /// Reads only the 44-byte header rather than `load(id:)`'s whole-file read — a reconciliation
    /// pass may be looking at an hour of audio, and every byte past the header is unneeded here.
    func sentHeader(id: String) -> (sampleRate: Int, dataSize: UInt32)? {
        guard let handle = try? FileHandle(forReadingFrom: sentURL(id: id)) else { return nil }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: WavHeaderReader.headerByteCount) else { return nil }
        return WavHeaderReader.parse(bytes)
    }
}
