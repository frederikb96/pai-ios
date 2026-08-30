import Foundation
import PAIKit
import UIKit
import UniformTypeIdentifiers

/// A photo, file or temporary note staged in the composer, not yet sent. Deliberately local-only
/// — the web never syncs staged attachments across devices either
/// (`docs/ARCHITECTURE.md`: "Attachments are not synced: they stay in the client that picked
/// them"), which is also why this lives beside the text field rather than in `DraftStore`.
struct StagedAttachment: Identifiable, Equatable {
    let id = UUID()
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

    var currentSize: Int { data.count }
    var wasCompressed: Bool { currentSize != originalSize }

    static func == (lhs: StagedAttachment, rhs: StagedAttachment) -> Bool {
        lhs.id == rhs.id
    }
}

/// Applies ``AttachmentStaging``'s plan: fit an oversized image's long edge to the bound, and
/// re-encode anything a consumer downstream could not open, keeping the original bytes whenever
/// a resize turned out not to save anything.
///
/// A re-encoded file is renamed to `.jpg` rather than keeping a stale extension, since the
/// extension is what decides inline serving on read-back — the web's own filename mismatch (a
/// `.png` name holding JPEG bytes) is an artifact of the canvas API keeping whatever name it was
/// given, not a decision worth copying.
enum AttachmentCompression {

    static func stage(data: Data, filename: String, mimeType: String) -> StagedAttachment {
        let originalSize = data.count

        guard let image = UIImage(data: data) else {
            return StagedAttachment(
                filename: filename, mimeType: mimeType, data: data, previewImage: nil, originalSize: originalSize)
        }

        let longestEdge = Double(max(image.size.width, image.size.height))
        let unchanged = StagedAttachment(
            filename: filename, mimeType: mimeType, data: data, previewImage: image, originalSize: originalSize)
        guard let plan = AttachmentStaging.plan(mimeType: mimeType, longestEdge: longestEdge) else {
            return unchanged
        }

        let targetSize = CGSize(
            width: image.size.width * plan.scale, height: image.size.height * plan.scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        guard let jpegData = resized.jpegData(compressionQuality: AttachmentStaging.jpegQuality) else {
            return unchanged
        }
        if plan.abandonIfNotSmaller, jpegData.count >= originalSize { return unchanged }

        return StagedAttachment(
            filename: Self.replacingExtension(of: filename, with: "jpg"), mimeType: "image/jpeg",
            data: jpegData, previewImage: resized, originalSize: originalSize
        )
    }

    private static func replacingExtension(of filename: String, with newExtension: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        let stem = base.isEmpty ? filename : base
        return "\(stem).\(newExtension)"
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

/// The server's own per-part cap (`MAX_UPLOAD_BYTES`, `config.py`). The web has no client-side
/// check at all — an oversize file stages, previews, and only fails at send with a 413 the user
/// discovers after waiting for the upload — which the composer's own source report calls out as
/// a genuine gap worth closing on iOS rather than porting faithfully.
let maxAttachmentBytes = 50 * 1024 * 1024

/// One decimal, `B`/`KB`/`MB` — matches the web's `formatFileSize`.
func formatFileSize(_ bytes: Int) -> String {
    let value = Double(bytes)
    switch value {
    case ..<1024: return "\(bytes) B"
    case ..<(1024 * 1024): return String(format: "%.1f KB", value / 1024)
    default: return String(format: "%.1f MB", value / (1024 * 1024))
    }
}
