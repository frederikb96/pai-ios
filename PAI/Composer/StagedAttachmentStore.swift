import Foundation
import Observation
import UIKit

/// What each session's composer has picked but not yet sent.
///
/// App-wide rather than held by the composer, for the same reason ``DraftStore`` is: leaving a
/// session and coming back is something people do mid-message — to check another session, to look
/// something up — and a photo picked before that trip is gone by the time they return, with no
/// sign it was ever there.
///
/// Local to this device on purpose. A staged file is bytes the backend has never seen, not a
/// draft it knows about — the web does not sync them either. Mirrored to disk under Application
/// Support so a force-quit loses nothing either: `loadPersisted()` reads that mirror back once,
/// at startup (`AppEnvironment.loadStartupState()`), the same way `RecordingAudioLibrary`'s own
/// storage is a thin, untested-on-Linux disk layer kept out of `PAIKit` on purpose.
/// File scope rather than a member: the background write reads it from a detached task, and a
/// static on a `@MainActor` type is isolated to that actor.
private let manifestFilename = "manifest.json"

@Observable
@MainActor
final class StagedAttachmentStore {
    private var bySession: [String: [StagedAttachment]] = [:]

    func attachments(for sessionID: String) -> [StagedAttachment] {
        bySession[sessionID] ?? []
    }

    func set(_ attachments: [StagedAttachment], for sessionID: String) {
        if attachments.isEmpty {
            bySession[sessionID] = nil
        } else {
            bySession[sessionID] = attachments
        }
        Self.persist(attachments, for: sessionID)
    }

    func append(_ attachments: [StagedAttachment], to sessionID: String) {
        set(self.attachments(for: sessionID) + attachments, for: sessionID)
    }

    func remove(id: StagedAttachment.ID, from sessionID: String) {
        set(attachments(for: sessionID).filter { $0.id != id }, for: sessionID)
    }

    /// Reads whatever `persist(_:for:)` wrote before this launch back into memory. Called once,
    /// before any screen can stage anything of its own — a later call would clobber an
    /// in-progress edit with whatever was on disk when the app last quit.
    func loadPersisted() async {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: Self.rootDirectory, includingPropertiesForKeys: nil)
        else { return }
        for directory in entries {
            guard let manifest = Self.readManifest(at: directory) else { continue }
            let restored = manifest.records.compactMap { Self.load($0, from: directory) }
            guard !restored.isEmpty, bySession[manifest.key] == nil else { continue }
            bySession[manifest.key] = restored
        }
    }

    // MARK: - Disk mirror
    //
    // A staged attachment's bytes never reach the backend until send, so the only place they can
    // survive a force-quit is here. One subdirectory per draft key, holding a manifest (the
    // key itself, plus each attachment's id/filename/mime/size) and one data file per attachment
    // named by its id — the manifest carries the key rather than the directory name encoding it,
    // so the sanitizing done to make a session id safe as a path component never has to be undone.

    private struct AttachmentRecord: Codable, Sendable {
        let id: String
        let filename: String
        let mimeType: String
        let originalSize: Int
    }

    private struct AttachmentManifest: Codable, Sendable {
        let key: String
        let records: [AttachmentRecord]
    }

    private static var rootDirectory: URL {
        let base =
            (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("StagedAttachments", isDirectory: true)
    }

    /// Serializes each session's disk writes to the order `set(_:for:)` called them in.
    /// `Task.detached` alone gives no such guarantee — two overlapping writes for the same key
    /// can finish in either order, and a "clear" (the empty-list branch below, called on send)
    /// that loses that race to a still-in-flight "add" leaves an already-sent attachment on disk
    /// for `loadPersisted()` to read back on the next launch, which is exactly the symptom this
    /// fixes: a photo that was sent reappearing in the composer after a relaunch. Each new write
    /// awaits whichever one preceded it for the same session, so completion order always matches
    /// call order regardless of how the scheduler happens to run them. Reads and writes of this
    /// dictionary only ever happen synchronously inside `persist`, itself only ever called from
    /// `set(_:for:)` on the main actor this whole type is isolated to — so there is no window
    /// between reading the previous task and installing the new one for a second call to land in.
    private static var pendingWrites: [String: Task<Void, Never>] = [:]

    /// Alphanumerics and hyphens survive as themselves — every session id and `DraftKey.newSession`
    /// already are that — anything else becomes `_` so a key can never escape its own directory.
    private static func directoryName(for key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return String(key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    /// Fire-and-forget from the caller's side — nothing in `set(_:for:)` awaits completion — but
    /// not from this method's own: each write awaits the previous one for the same key before
    /// touching disk, via `pendingWrites`, so a write racing a later one for the same key can
    /// only ever lose to a *newer* snapshot, matching what the old comment here claimed before
    /// `Task.detached` scheduling order turned out not to guarantee it.
    private static func persist(_ attachments: [StagedAttachment], for sessionID: String) {
        let directory = rootDirectory.appendingPathComponent(directoryName(for: sessionID), isDirectory: true)
        let manifest = AttachmentManifest(
            key: sessionID,
            records: attachments.map {
                AttachmentRecord(
                    id: $0.id.uuidString, filename: $0.filename, mimeType: $0.mimeType, originalSize: $0.originalSize)
            })
        let files = attachments.map { (name: $0.id.uuidString, data: $0.data) }
        let previous = pendingWrites[sessionID]
        let task = Task.detached(priority: .utility) {
            _ = await previous?.value
            let fileManager = FileManager.default
            guard !manifest.records.isEmpty else {
                try? fileManager.removeItem(at: directory)
                return
            }
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            // A deliberate answer, not an accidental default: a staged attachment is bytes the
            // backend has never seen, so — like a recording — device backup is the only
            // redundancy it ever gets before it is sent. Left included on purpose, matching
            // `FileRecordingAudioStorage`'s identical decision on the same question; excluding
            // one of the two and not the other would be its own inconsistency bug.
            var resource = URLResourceValues()
            resource.isExcludedFromBackup = false
            var excludable = directory
            try? excludable.setResourceValues(resource)
            if let encoded = try? JSONEncoder().encode(manifest) {
                try? encoded.write(to: directory.appendingPathComponent(manifestFilename), options: .atomic)
            }
            let keep = Set(files.map(\.name)).union([manifestFilename])
            if let existing = try? fileManager.contentsOfDirectory(atPath: directory.path) {
                for name in existing where !keep.contains(name) {
                    try? fileManager.removeItem(at: directory.appendingPathComponent(name))
                }
            }
            for file in files {
                try? file.data.write(to: directory.appendingPathComponent(file.name), options: .atomic)
            }
        }
        pendingWrites[sessionID] = task
    }

    private static func readManifest(at directory: URL) -> AttachmentManifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(manifestFilename)) else { return nil }
        return try? JSONDecoder().decode(AttachmentManifest.self, from: data)
    }

    /// A record whose data file is missing or unreadable is dropped rather than surfaced as an
    /// empty attachment — the file it names is simply gone, the same as any other cache eviction.
    private static func load(_ record: AttachmentRecord, from directory: URL) -> StagedAttachment? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(record.id)) else { return nil }
        let id = UUID(uuidString: record.id) ?? UUID()
        let previewImage = record.mimeType.hasPrefix("image/") ? UIImage(data: data) : nil
        return StagedAttachment(
            id: id, filename: record.filename, mimeType: record.mimeType, data: data, previewImage: previewImage,
            originalSize: record.originalSize)
    }
}
