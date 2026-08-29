import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The camera-roll half of "Add Photo" — `PHPickerViewController` needs no Photo Library usage
/// description at all for a plain selection (Apple's own privacy model: the picker runs
/// out-of-process and only what the user taps is handed back), unlike the old
/// `UIImagePickerController` full-library mode. `selectionLimit = 0` matches the web's
/// `multiple` attribute on its hidden `<input>`.
struct PhotoAttachmentPicker: UIViewControllerRepresentable {
    var onPicked: ([StagedAttachment]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 0
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: ([StagedAttachment]) -> Void

        init(onPicked: @escaping ([StagedAttachment]) -> Void) {
            self.onPicked = onPicked
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { return }

            let group = DispatchGroup()
            var staged: [StagedAttachment?] = Array(repeating: nil, count: results.count)

            for (index, result) in results.enumerated() {
                group.enter()
                let provider = result.itemProvider
                let suggestedName = provider.suggestedName
                guard
                    let typeIdentifier = provider.registeredTypeIdentifiers.first(where: {
                        UTType($0)?.conforms(to: .image) == true
                    })
                else {
                    group.leave()
                    continue
                }
                provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                    defer { group.leave() }
                    guard let data else { return }
                    let ext = UTType(typeIdentifier)?.preferredFilenameExtension ?? "jpg"
                    let filename = suggestedName.map { $0.contains(".") ? $0 : "\($0).\(ext)" } ?? "image.\(ext)"
                    let mimeType = UTType(typeIdentifier)?.preferredMIMEType ?? "image/jpeg"
                    staged[index] = AttachmentCompression.stage(data: data, filename: filename, mimeType: mimeType)
                }
            }

            group.notify(queue: .main) {
                self.onPicked(staged.compactMap { $0 })
            }
        }
    }
}
