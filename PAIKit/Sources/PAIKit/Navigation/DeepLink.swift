import Foundation
import Observation

/// Somewhere in the app that something outside the app asked for: a tapped notification, a
/// home-screen shortcut, a URL.
///
/// Carries an id and nothing else, for the same reason ``Route`` does — a shortcut is configured
/// once and opened months later, so anything richer would be describing a note that has since
/// been renamed, moved or deleted.
public enum DeepLink: Equatable, Sendable, Hashable {
    case session(id: String)
    case note(id: String)

    /// The routes this link lands on. Whole paths rather than single routes: a deep link arrives
    /// knowing nothing about what the app was showing, so it replaces the stack, and a note with
    /// no index underneath it would have nowhere for Back to go.
    public var routes: [Route] {
        switch self {
        case .session(let id): return [.session(id: id)]
        case .note(let id): return [.notes, .note(id: id)]
        }
    }
}

extension DeepLink {

    /// The APNs payload keys the backend sends alongside the alert.
    ///
    /// Prefixed because the payload is a flat dictionary shared with Apple's own reserved keys,
    /// and an unprefixed `session_id` is exactly the sort of name a future addition collides
    /// with.
    public static let sessionIDKey = "pai_session_id"
    public static let noteIDKey = "pai_note_id"

    /// Reads a link out of a notification's `userInfo`.
    ///
    /// Takes `[String: String]` rather than the `[AnyHashable: Any]` the system hands over, so
    /// the parsing is a pure function that is tested on Linux for nothing; flattening the
    /// system's dictionary is one line at the call site and is the part that genuinely cannot be
    /// tested.
    ///
    /// A payload naming both is read as the session — a push about a session that also mentions
    /// a note is still about the session, and silently picking the other one would send the
    /// reader somewhere they did not ask to go.
    public static func from(payload: [String: String]) -> DeepLink? {
        if let id = payload[sessionIDKey], !id.isEmpty { return .session(id: id) }
        if let id = payload[noteIDKey], !id.isEmpty { return .note(id: id) }
        return nil
    }

    /// The custom URL scheme, for a shortcut or a widget that opens the app by URL rather than
    /// through an App Intent.
    ///
    /// `pai://session/<id>` and `pai://note/<id>`. Rejects anything else rather than guessing,
    /// including a well-formed URL with an unknown host — a link the app does not understand
    /// must not silently open some other screen.
    public static func from(url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == "pai",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        // Split the *encoded* path. `URL.path` decodes first, which turns an id's escaped slash
        // back into a separator and splits one segment into two — so an id containing a slash
        // would parse as a malformed link rather than as itself.
        //
        // A URL's host is its authority, so `pai://note/<id>` puts "note" in the host and the id
        // in the first path component; reading the path alone as well covers `pai:///note/<id>`,
        // which is what a caller building the URL from components produces.
        var segments = components.percentEncodedPath.split(separator: "/").map(String.init)
        if let host = components.percentEncodedHost, !host.isEmpty { segments.insert(host, at: 0) }
        guard segments.count == 2 else { return nil }
        let id = segments[1].removingPercentEncoding ?? segments[1]
        guard !id.isEmpty else { return nil }
        switch segments[0].lowercased() {
        case "session": return .session(id: id)
        case "note": return .note(id: id)
        default: return nil
        }
    }

    public var url: URL? {
        switch self {
        case .session(let id): return URL(string: "pai://session/\(Self.escape(id))")
        case .note(let id): return URL(string: "pai://note/\(Self.escape(id))")
        }
    }

    /// `.urlPathAllowed` permits `/`, which is the one character that must not survive: an id
    /// containing one would split into a third path segment and fail to parse back.
    private static let idAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))

    private static func escape(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: Self.idAllowed) ?? id
    }
}

/// Where a deep link waits until the app is in a state that can act on it.
///
/// A process-wide inbox rather than a value passed in, because the things that produce a link —
/// an app-delegate callback, an App Intent, a URL open — all run before or outside anything that
/// holds the app's own state, and none of them is handed a reference to it. Parking is not an
/// optimisation: a notification that launches the app from cold delivers its tap *before* there
/// is a router, a connection or a signed-in user, and a link acted on immediately would be acted
/// on against a sign-in screen and lost.
///
/// Holds one link, not a queue. Two taps before the app is ready means the person tapped twice
/// and wants the second one.
@MainActor
@Observable
public final class DeepLinkInbox {

    public static let shared = DeepLinkInbox()

    public private(set) var pending: DeepLink?

    public init() {}

    public func receive(_ link: DeepLink) {
        pending = link
    }

    /// Take the pending link, if there is one, clearing it.
    ///
    /// Clearing on read rather than after the navigation lands is deliberate: a link that stayed
    /// pending would be re-consumed by the next thing that observes the inbox, which is how a
    /// deep link becomes a screen the reader cannot navigate away from.
    public func consume() -> DeepLink? {
        defer { pending = nil }
        return pending
    }
}
