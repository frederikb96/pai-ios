import Foundation

/// A link into the Browser app: `https://<backend host>/apps/browser` (the list) or
/// `.../apps/browser/<name>` (one session — what the agent drops in chat to hand a page over).
public enum BrowserLink: Equatable, Sendable {
    case list
    case session(name: String)

    /// The backend's session-name rule (`SESSION_NAME_RE` in `browser_relay.py`).
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.unicodeScalars.count <= 64 else { return false }
        let alphanumeric = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard alphanumeric.contains(first) else { return false }
        let allowed = alphanumeric.union(CharacterSet(charactersIn: "._-"))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// The link `url` stands for when it is an https link into this backend's Browser app, else
    /// `nil` — a link to any other host is an ordinary external link.
    public static func parse(_ url: URL, backendHost: String?) -> BrowserLink? {
        guard url.scheme?.lowercased() == "https", let backendHost,
            url.host?.lowercased() == backendHost.lowercased()
        else { return nil }
        return parse(percentEncodedPath: url.path(percentEncoded: true))
    }

    /// The same link as a path alone: used where the host is already settled (a universal link
    /// the system matched to the app's own domain).
    public static func parse(percentEncodedPath path: String) -> BrowserLink? {
        let segments = path.split(separator: "/").map(String.init)
        guard segments.count >= 2, segments[0] == "apps", segments[1] == "browser" else { return nil }
        if segments.count == 2 { return .list }
        guard segments.count == 3 else { return nil }
        let name = segments[2].removingPercentEncoding ?? segments[2]
        return isValidName(name) ? .session(name: name) : nil
    }
}
