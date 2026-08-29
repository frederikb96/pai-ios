import Foundation
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

/// Ports the web's `compressImage` contract exactly (`utils/image.ts`): touch only images, leave
/// anything already within 1920px on both axes alone, otherwise fit the long edge to 1920 and
/// re-encode as JPEG at quality 0.85 — keeping the original if the result is not actually
/// smaller. The one deliberate divergence, flagged in the composer's own source report as the
/// right call: a re-encoded file is renamed to `.jpg` rather than keeping a stale extension,
/// since the extension is what decides inline serving on read-back and the web's own filename
/// mismatch (a `.png` name holding JPEG bytes) was never a decision, just an artifact of the
/// canvas API keeping whatever name it was given.
enum AttachmentCompression {
    static let maxDimension: CGFloat = 1920
    static let jpegQuality: CGFloat = 0.85

    static func stage(data: Data, filename: String, mimeType: String) -> StagedAttachment {
        let originalSize = data.count

        guard mimeType.hasPrefix("image/"), mimeType != "image/svg+xml", let image = UIImage(data: data) else {
            return StagedAttachment(
                filename: filename, mimeType: mimeType, data: data, previewImage: nil, originalSize: originalSize)
        }

        let longestEdge = max(image.size.width, image.size.height)
        guard longestEdge > maxDimension else {
            return StagedAttachment(
                filename: filename, mimeType: mimeType, data: data, previewImage: image, originalSize: originalSize
            )
        }

        let scale = maxDimension / longestEdge
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        guard let jpegData = resized.jpegData(compressionQuality: jpegQuality), jpegData.count < originalSize else {
            return StagedAttachment(
                filename: filename, mimeType: mimeType, data: data, previewImage: image, originalSize: originalSize
            )
        }

        let jpegFilename = Self.replacingExtension(of: filename, with: "jpg")
        return StagedAttachment(
            filename: jpegFilename, mimeType: "image/jpeg", data: jpegData, previewImage: resized,
            originalSize: originalSize
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
