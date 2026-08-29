import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The "Add File" half of the plus menu — `UIDocumentPickerViewController` reaches the whole
/// Files app (iCloud Drive, on-device, any provider extension), matching the web's file `<input>`
/// with no `accept` list at all, which the source report calls out as reaching a different phone
/// UI than the photo picker for exactly that reason.
struct FileAttachmentPicker: UIViewControllerRepresentable {
    var onPicked: ([StagedAttachment]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        controller.allowsMultipleSelection = true
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: ([StagedAttachment]) -> Void

        init(onPicked: @escaping ([StagedAttachment]) -> Void) {
            self.onPicked = onPicked
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            let staged: [StagedAttachment] = urls.compactMap { url in
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return nil }
                let mimeType =
                    UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                return AttachmentCompression.stage(data: data, filename: url.lastPathComponent, mimeType: mimeType)
            }
            onPicked(staged)
        }
    }
}
