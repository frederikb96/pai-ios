import PAIKit
import SwiftUI

/// Walks the full-screen viewer through the pictures of one session's loaded messages. Built when
/// a transcript picture is tapped, from the messages as they are at that moment; the pictures a
/// session gains while the viewer is open are not part of it.
///
/// A picture that is gone or does not decode is skipped, and skipped again without a second
/// request on later steps.
@MainActor
final class PictureStepper {
    private let sessionID: String
    private let apiClient: PaiApiClient
    private let paths: [String]
    private var current: String
    private var unavailable: Set<String> = []

    private init(sessionID: String, apiClient: PaiApiClient, paths: [String], current: String) {
        self.sessionID = sessionID
        self.apiClient = apiClient
        self.paths = paths
        self.current = current
    }

    /// The step provider for the picture at `path`, or `nil` when the loaded messages hold no
    /// other picture to step to.
    static func step(
        from path: String, sessionID: String, messages: [Message], apiClient: PaiApiClient
    ) -> FilePreviewTarget.Step? {
        let paths = SessionPictures.paths(in: messages)
        guard paths.count > 1, paths.contains(path) else { return nil }
        let stepper = PictureStepper(sessionID: sessionID, apiClient: apiClient, paths: paths, current: path)
        return { direction in await stepper.stepped(direction) }
    }

    private func stepped(_ direction: PictureStepDirection) async -> FilePreviewTarget? {
        for path in SessionPictures.neighbours(of: current, in: paths, direction: direction)
        where !unavailable.contains(path) {
            if let target = await target(for: path) {
                current = path
                return target
            }
            unavailable.insert(path)
        }
        return nil
    }

    /// The picture's bytes from the transcript's thumbnail cache when it holds them, else from the
    /// attachment route.
    private func target(for path: String) async -> FilePreviewTarget? {
        let key = SessionInlineImageCache.key(sessionID: sessionID, path: path)
        let data: Data
        if let entry = SessionInlineImageCache.shared.entry(for: key) {
            data = entry.data
        } else {
            guard let result = try? await apiClient.getAttachment(sessionId: sessionID, path: path),
                case .ok(let bytes, _) = result
            else { return nil }
            data = bytes
        }
        let target = FilePreviewTarget(
            data: data, filename: attachmentFilename(path), step: { direction in await self.stepped(direction) })
        guard case .image = target.content else { return nil }
        return target
    }
}
