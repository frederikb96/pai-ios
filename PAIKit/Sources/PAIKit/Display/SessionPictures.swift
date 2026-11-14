import Foundation

/// Which way the full-screen viewer steps through a session's pictures.
public enum PictureStepDirection: Sendable {
    /// Towards older messages.
    case previous
    /// Towards newer messages.
    case next
}

/// The pictures of a session's loaded messages, in the order a reader meets them, for stepping
/// from one to the next in the full-screen viewer.
public enum SessionPictures {

    /// The image paths the messages show: files a user attached and images a reply's `pai-file:`
    /// lines name, in transcript order, each path once (its first appearance). Only what is in
    /// `messages` counts, so a picture in older history that was never loaded is not reachable.
    public static func paths(in messages: [Message]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for message in messages {
            for path in imagePaths(of: message) where seen.insert(path).inserted {
                result.append(path)
            }
        }
        return result
    }

    /// The paths a step from `path` can land on, nearest first: everything older for
    /// ``PictureStepDirection/previous``, everything newer for ``PictureStepDirection/next``. Empty
    /// when `path` is not in `paths`. A caller whose nearest picture fails to load tries the next.
    public static func neighbours(of path: String, in paths: [String], direction: PictureStepDirection) -> [String] {
        guard let index = paths.firstIndex(of: path) else { return [] }
        switch direction {
        case .previous: return Array(paths[..<index].reversed())
        case .next: return Array(paths[(index + 1)...])
        }
    }

    private static func imagePaths(of message: Message) -> [String] {
        let candidates: [String]
        switch MessageRouting.route(for: message) {
        case .user(_, let paths), .resentUser(_, let paths), .command(_, _, let paths):
            candidates = paths
        case .assistant:
            candidates = FileMarkers.split(message.content ?? "").compactMap {
                if case .file(let path) = $0 { return path }
                return nil
            }
        default:
            candidates = []
        }
        return candidates.filter(isImageAttachmentPath)
    }
}
