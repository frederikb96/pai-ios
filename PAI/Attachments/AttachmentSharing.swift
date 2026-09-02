import SwiftUI

/// The iOS share sheet every non-image attachment (a note's download chip, a session's `pai-file:`
/// marker, a session's own attachment) hands its bytes to — one wrapper, so a caller reaches for
/// this instead of writing a second `UIActivityViewController` bridge.
struct AttachmentShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// One file staged for ``AttachmentShareSheet``, identified by its temp path so `.sheet(item:)`
/// treats a new file as a new presentation rather than reusing a dismissed one.
struct AttachmentShareFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

enum AttachmentSharing {
    /// Writes `data` to a fresh temp file named `filename` and hands back what
    /// `AttachmentShareFile` needs — the one path every non-image share flow (a note's download
    /// chip, a session attachment, a `pai-file:` marker) goes through, so a failed write is
    /// handled once rather than once per caller.
    static func stage(_ data: Data, filename: String) -> AttachmentShareFile? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        // A failed write produces nothing to share — quieter than the failure deserves, but not
        // wrong: this is a temp-directory write with no real reason to fail.
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return AttachmentShareFile(url: url)
    }
}

/// The extensions every attachment surface treats as an image to show inline rather than as a
/// download — kept in one place so a file that renders in Notes also renders in a session.
let attachmentImageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic"]

func isImageAttachmentPath(_ path: String) -> Bool {
    let ext = (attachmentFilename(path) as NSString).pathExtension.lowercased()
    return attachmentImageExtensions.contains(ext)
}

/// The filename portion of a VM attachment path, for display.
func attachmentFilename(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
}
