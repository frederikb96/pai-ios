import Foundation
import PAIKit
import UniformTypeIdentifiers

/// Turns what the share sheet hands over into files in this extension's temporary directory.
///
/// A provider's temporary file is valid only inside its own callback, and it can sit on a slow
/// source such as iCloud, so everything is copied out up front. The sending half then has nothing
/// left to wait on but the network.
@MainActor
enum SharedItemLoader {

    struct Loaded {
        let items: [ShareItem]
        let refusal: String?
    }

    private struct OversizeImage: LocalizedError {
        var errorDescription: String? { "exceeds the 50MB limit even after resizing." }
    }

    private enum Payload: Sendable {
        case file(URL)
        case text(String, filename: String)
    }

    /// Reused across shares so an interrupted one cannot leave anything behind for long.
    private nonisolated static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("shared", isDirectory: true)
    }

    static func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func load(_ providers: [NSItemProvider]) async -> Loaded {
        removeTemporaryFiles()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var items: [ShareItem] = []
        var unreadable: [String] = []
        var oversize: [String] = []
        for provider in providers {
            guard let payload = await payload(of: provider) else {
                unreadable.append(provider.suggestedName ?? "A shared item")
                continue
            }
            switch payload {
            case .file(let url):
                let name = url.lastPathComponent
                let mimeType =
                    UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                    ?? "application/octet-stream"
                let isImage = mimeType.hasPrefix("image/")
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                // An image is measured after fitting, which is what actually gets sent.
                guard isImage || size <= maxAttachmentBytes else {
                    oversize.append(name)
                    continue
                }
                items.append(
                    ShareItem(name: name) {
                        let data = try Data(contentsOf: url, options: .mappedIfSafe)
                        guard isImage else {
                            return PaiFileUpload(filename: name, mimeType: mimeType, data: data)
                        }
                        let fitted = AttachmentImageFit.apply(data: data, filename: name, mimeType: mimeType)
                        guard fitted.data.count <= maxAttachmentBytes else {
                            throw OversizeImage()
                        }
                        return PaiFileUpload(filename: fitted.filename, mimeType: fitted.mimeType, data: fitted.data)
                    })
            case .text(let text, let filename):
                items.append(
                    ShareItem(name: filename) {
                        PaiFileUpload(filename: filename, mimeType: "text/plain", data: Data(text.utf8))
                    })
            }
        }
        return Loaded(items: items, refusal: refusalMessage(unreadable: unreadable, oversize: oversize))
    }

    private static func refusalMessage(unreadable: [String], oversize: [String]) -> String? {
        var parts: [String] = []
        if let first = oversize.first {
            let suffix = oversize.count > 1 ? " and \(oversize.count - 1) other file(s)" : ""
            parts.append("\(first)\(suffix) exceeds the 50MB limit and was not attached.")
        }
        if let first = unreadable.first {
            let suffix = unreadable.count > 1 ? " and \(unreadable.count - 1) other item(s)" : ""
            parts.append("\(first)\(suffix) could not be read.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// A web link is the one thing conforming to `public.data` that has no file behind it, so it
    /// is asked for first and arrives as a small text file, as selected text does.
    private static func payload(of provider: NSItemProvider) async -> Payload? {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
            !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
            let link = await url(from: provider)
        {
            return .text(link.absoluteString, filename: "link.txt")
        }
        if let type = provider.registeredTypeIdentifiers.first(where: isFileType),
            let file = await fileCopy(from: provider, type: type)
        {
            return .file(file)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
            let text = await text(from: provider)
        {
            return .text(text, filename: "shared-text.txt")
        }
        return nil
    }

    private static func isFileType(_ identifier: String) -> Bool {
        guard let type = UTType(identifier) else { return false }
        return type.conforms(to: .data) && !type.conforms(to: .url)
    }

    // The callbacks below are marked `@Sendable` because a closure formed here would otherwise take
    // on this type's main-actor isolation, and the provider calls it from a background queue.
    private static func url(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { @Sendable url, _ in continuation.resume(returning: url) }
        }
    }

    private static func text(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { @Sendable text, _ in
                continuation.resume(returning: text)
            }
        }
    }

    private static func fileCopy(from provider: NSItemProvider, type: String) async -> URL? {
        let destinationFolder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { @Sendable source, _ in
                guard let source else {
                    continuation.resume(returning: nil)
                    return
                }
                let name = fileName(source: source, suggestedName: suggestedName)
                let destination = destinationFolder.appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: source, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// The provider's name reads better than a temporary file's, and often has no extension, which
    /// is what decides how the file is typed and served.
    private nonisolated static func fileName(source: URL, suggestedName: String?) -> String {
        guard let suggestedName, !suggestedName.isEmpty else { return source.lastPathComponent }
        let safeName = suggestedName.replacingOccurrences(of: "/", with: "-")
        if (safeName as NSString).pathExtension.isEmpty, !source.pathExtension.isEmpty {
            return "\(safeName).\(source.pathExtension)"
        }
        return safeName
    }
}
