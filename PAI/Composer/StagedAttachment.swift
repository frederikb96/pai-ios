import Foundation
import PAIKit
import UIKit
import UniformTypeIdentifiers

/// Whether a staged attachment has reached the draft on the server yet — uploaded the instant it
/// is picked, so one message can be composed from several devices (adding images from
/// a laptop while dictating on a phone), rather than only at send. `.uploaded` is what lets
/// `postMessage` skip re-sending the bytes: the backend's own `_claim_draft_attachments` already
/// moves anything staged under this draft key onto the session at send time.
enum AttachmentUploadState: Equatable {
    case uploading
    case uploaded(attachmentId: String)
    /// The upload failed — `postMessage` falls back to sending the bytes directly at send time,
    /// same as before this existed, so a flaky connection never loses the attachment outright.
    case failed
}

/// A photo, file or temporary note staged in the composer, not yet sent. The bytes themselves
/// stay local until sent (or until the background upload below succeeds) — but unlike before,
/// every staged attachment now uploads onto the draft immediately, which is what makes it visible
/// on the user's other devices while they are still composing.
struct StagedAttachment: Identifiable, Equatable {
    /// Settable so a restore from disk can keep the id it was stored under. Left to itself it
    /// would be given a fresh one, and the data file named after the old id would be treated as
    /// stale and rewritten on the next save.
    var id = UUID()
    /// The id of the server row this file becomes, given to its upload. Known before that upload
    /// is answered, which is what lets a send name it. Lower-cased because the server lists ids
    /// that way.
    var uploadId: String { id.uuidString.lowercased() }
    var filename: String
    var mimeType: String
    var data: Data
    /// Set only for an image, so the preview strip can show a thumbnail instead of a filename
    /// chip without re-decoding `data` on every redraw.
    var previewImage: UIImage?
    /// Bytes before compression — equal to `data.count` when nothing was re-encoded, which is
    /// exactly the test the preview strip uses to decide whether to show the
    /// "2.4 MB → 810.3 KB" caption.
    var originalSize: Int
    /// `nil` until the background upload starts. A file restored from a previous launch comes
    /// back `.uploaded` when the draft row it became was recorded alongside it — without that,
    /// the send would treat an already-uploaded file as never uploaded and attach it twice.
    var uploadState: AttachmentUploadState?
    /// When the upload landed in this launch; `nil` for one restored from disk.
    var uploadedAt: Date?

    /// The draft-attachment row this became on the server, or `nil` while it is only local.
    /// What joins a staged file to the row another device would see.
    var remoteAttachmentId: String? {
        guard case .uploaded(let id) = uploadState else { return nil }
        return id
    }

    var currentSize: Int { data.count }
    var wasCompressed: Bool { currentSize != originalSize }

    static func == (lhs: StagedAttachment, rhs: StagedAttachment) -> Bool {
        lhs.id == rhs.id
    }
}

/// A staged attachment built from ``AttachmentImageFit``, the same fitting a shared file gets.
enum AttachmentCompression {

    static func stage(data: Data, filename: String, mimeType: String) -> StagedAttachment {
        let fitted = AttachmentImageFit.apply(data: data, filename: filename, mimeType: mimeType)
        return StagedAttachment(
            filename: fitted.filename, mimeType: fitted.mimeType, data: fitted.data, previewImage: fitted.image,
            originalSize: data.count)
    }
}

/// `(name, content) -> file`, exactly as the source report describes it: nothing about it
/// resembles a draft, and content is passed through byte-for-byte — notes are written to be
/// parsed, and some contain secrets whose whitespace is not this code's business.
enum TemporaryNote {
    static func makeFile(name: String, content: String) -> StagedAttachment {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmedName.isEmpty ? "note" : trimmedName
        let filename = base.contains(".") ? base : "\(base).txt"
        let data = Data(content.utf8)
        return StagedAttachment(
            filename: filename, mimeType: "text/plain", data: data, previewImage: nil, originalSize: data.count)
    }
}

/// One decimal, `B`/`KB`/`MB` — matches the web's `formatFileSize`.
func formatFileSize(_ bytes: Int) -> String {
    let value = Double(bytes)
    switch value {
    case ..<1024: return "\(bytes) B"
    case ..<(1024 * 1024): return String(format: "%.1f KB", value / 1024)
    default: return String(format: "%.1f MB", value / (1024 * 1024))
    }
}
