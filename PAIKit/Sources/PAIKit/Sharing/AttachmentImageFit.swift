#if canImport(UIKit)
    import Foundation
    import UIKit

    /// Applies ``AttachmentStaging``'s plan: fit an oversized image's long edge to the bound, and
    /// re-encode anything a consumer downstream could not open, keeping the original bytes whenever
    /// a resize turned out not to save anything.
    ///
    /// A re-encoded file is renamed to `.jpg` rather than keeping a stale extension, since the
    /// extension is what decides inline serving on read-back.
    public enum AttachmentImageFit {

        public struct Result {
            public let filename: String
            public let mimeType: String
            public let data: Data
            /// `nil` when the bytes are not an image.
            public let image: UIImage?
        }

        public static func apply(data: Data, filename: String, mimeType: String) -> Result {
            guard let image = UIImage(data: data) else {
                return Result(filename: filename, mimeType: mimeType, data: data, image: nil)
            }

            let longestEdge = Double(max(image.size.width, image.size.height))
            let unchanged = Result(filename: filename, mimeType: mimeType, data: data, image: image)
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
            if plan.abandonIfNotSmaller, jpegData.count >= data.count { return unchanged }

            return Result(
                filename: replacingExtension(of: filename, with: "jpg"), mimeType: "image/jpeg", data: jpegData,
                image: resized)
        }

        private static func replacingExtension(of filename: String, with newExtension: String) -> String {
            let base = (filename as NSString).deletingPathExtension
            let stem = base.isEmpty ? filename : base
            return "\(stem).\(newExtension)"
        }
    }
#endif
