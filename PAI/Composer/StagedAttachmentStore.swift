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

    /// Alphanumerics and hyphens survive as themselves — every session id and `DraftKey.newSession`
    /// already are that — anything else becomes `_` so a key can never escape its own directory.
    private static func directoryName(for key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return String(key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    /// Fire-and-forget on purpose, matching every other write in this store: nothing here awaits
    /// completion, and a write racing a later one for the same key only ever loses to a *newer*
    /// snapshot, since `set(_:for:)` is the only caller and each call carries the full current
    /// list.
    private static func persist(_ attachments: [StagedAttachment], for sessionID: String) {
        let directory = rootDirectory.appendingPathComponent(directoryName(for: sessionID), isDirectory: true)
        let manifest = AttachmentManifest(
            key: sessionID,
            records: attachments.map {
                AttachmentRecord(
                    id: $0.id.uuidString, filename: $0.filename, mimeType: $0.mimeType, originalSize: $0.originalSize)
            })
        let files = attachments.map { (name: $0.id.uuidString, data: $0.data) }
        Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard !manifest.records.isEmpty else {
                try? fileManager.removeItem(at: directory)
                return
            }
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
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
