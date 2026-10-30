import PAIKit
import SwiftUI
import UIKit

/// The system camera, presented for one shot. The photo goes straight onto the draft and never
/// reaches the photo library, so no library permission is involved, only the camera's own.
struct CameraCapture: UIViewControllerRepresentable {
    var onCaptured: (StagedAttachment) -> Void

    /// False on a simulator; the entries that open this are left out there.
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCaptured: onCaptured) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCaptured: (StagedAttachment) -> Void

        init(onCaptured: @escaping (StagedAttachment) -> Void) {
            self.onCaptured = onCaptured
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            defer { picker.dismiss(animated: true) }
            guard let image = info[.originalImage] as? UIImage,
                let data = image.jpegData(compressionQuality: AttachmentStaging.jpegQuality)
            else { return }
            let stamp = Int(Date().timeIntervalSince1970)
            onCaptured(AttachmentCompression.stage(data: data, filename: "photo-\(stamp).jpg", mimeType: "image/jpeg"))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
