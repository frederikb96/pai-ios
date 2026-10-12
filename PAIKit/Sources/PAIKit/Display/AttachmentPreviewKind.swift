import Foundation

/// How the app previews a file without saving it: an image or a PDF opens in the full-screen file
/// viewer, anything else has no preview and goes through the download flow.
///
/// Decided from the filename alone, so every surface that offers a file (a transcript chip, a
/// note embed, the canteen's menus) agrees on which files open in place.
public enum AttachmentPreviewKind: Equatable, Sendable {
    case image
    case pdf
    case other

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic"]

    /// - Parameter path: a bare filename or a VM/vault path; only its last component counts.
    public init(path: String) {
        let ext = (attachmentFilename(path) as NSString).pathExtension.lowercased()
        if Self.imageExtensions.contains(ext) {
            self = .image
        } else if ext == "pdf" {
            self = .pdf
        } else {
            self = .other
        }
    }

    /// Whether the viewer can show the file itself rather than a "no preview" card.
    public var isPreviewable: Bool { self != .other }
}

public func isImageAttachmentPath(_ path: String) -> Bool {
    AttachmentPreviewKind(path: path) == .image
}

/// The filename portion of a VM attachment path, for display.
public func attachmentFilename(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
}
