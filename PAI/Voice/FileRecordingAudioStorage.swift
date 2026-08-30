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
}
