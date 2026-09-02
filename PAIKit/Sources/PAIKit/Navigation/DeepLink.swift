import Foundation
import Observation

/// Somewhere in the app that something outside the app asked for: a tapped notification, a
/// home-screen shortcut, a URL.
///
/// Carries an id and nothing else, for the same reason ``Route`` does — a shortcut is configured
/// once and opened months later, so anything richer would be describing a note that has since
/// been renamed, moved or deleted. `notesList` and `createSession` carry nothing at all, for the
/// same reason: there is nothing about either destination a shortcut could still be describing
/// months later.
public enum DeepLink: Equatable, Sendable, Hashable {
    /// `messageID` is where to jump once the transcript is open — see ``Route/session(id:messageID:)``.
    case session(id: String, messageID: Int? = nil)
    case note(id: String)
    case notesList
    case createSession
    /// A tapped push notification (row 5.28), named only by its own id — at send time the backend
    /// does not yet know which transcript message it will resolve to (`notifications.py`'s anchor
    /// is filled in lazily), so the payload can only ever carry the notification's own id. Unlike
    /// every other case, ``routes`` cannot answer this one without a network round trip: resolving
    /// it is `RootView`'s job (`resolveAndOpenNotification`), which fetches
    /// `GET /api/notifications/{id}` and routes on what comes back — a session with its anchor if
    /// one resolved, the centre for an alert, or the centre as the graceful fallback for anything
    /// that failed to resolve. ``routes`` still answers something for this case (the centre) so
    /// the type stays total, but nothing in the app is expected to call it for `.notification`.
    case notification(id: String)

    /// The routes this link lands on. Whole paths rather than single routes: a deep link arrives
    /// knowing nothing about what the app was showing, so it replaces the stack, and a note with
    /// no index underneath it would have nowhere for Back to go.
    public var routes: [Route] {
        switch self {
        case .session(let id, let messageID): return [.session(id: id, messageID: messageID)]
        case .note(let id): return [.notes, .note(id: id)]
        case .notesList: return [.notes]
        case .createSession: return [.createSession]
        case .notification: return [.notifications]
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
    /// Present alongside `sessionIDKey` only if a sender ever resolves the jump target itself
    /// before the push goes out — `push.py`'s own notification link never does this today (see
    /// `.notification`'s doc comment), so this key is read defensively rather than relied on.
    public static let messageIDKey = "pai_message_id"
    /// What `mcp_server.notify` and `alerting._send_push` both actually put in `link` — see
    /// `notifications`'s doc comment for why this, not a resolved session/message pair, is what
    /// arrives on the wire.
    public static let notificationIDKey = "pai_notification_id"

    /// Reads a link out of a notification's `userInfo`.
    ///
    /// Takes `[String: String]` rather than the `[AnyHashable: Any]` the system hands over, so
    /// the parsing is a pure function that is tested on Linux for nothing; flattening the
    /// system's dictionary is one line at the call site and is the part that genuinely cannot be
    /// tested.
    ///
    /// Checked in a fixed order for a payload naming more than one: the notification id first,
    /// since that is what every push this app currently sends for an agent or alert notification
    /// actually carries; then session, then note — a push about a session that also mentions a
    /// note is still about the session, and silently picking the other one would send the reader
    /// somewhere they did not ask to go.
    public static func from(payload: [String: String]) -> DeepLink? {
        if let id = payload[notificationIDKey], !id.isEmpty { return .notification(id: id) }
        if let id = payload[sessionIDKey], !id.isEmpty {
            let messageID = payload[messageIDKey].flatMap(Int.init)
            return .session(id: id, messageID: messageID)
        }
        if let id = payload[noteIDKey], !id.isEmpty { return .note(id: id) }
        return nil
    }

    /// The custom URL scheme, for a shortcut or a widget that opens the app by URL rather than
    /// through an App Intent.
    ///
    /// `pai://session/<id>`, `pai://note/<id>`, `pai://notes` and `pai://createsession`. Rejects
    /// anything else rather than guessing, including a well-formed URL with an unknown host — a
    /// link the app does not understand must not silently open some other screen.
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
        guard let kind = segments.first else { return nil }
        switch kind.lowercased() {
        case "session", "note", "notification":
            guard segments.count == 2 else { return nil }
            let id = segments[1].removingPercentEncoding ?? segments[1]
            guard !id.isEmpty else { return nil }
            switch kind.lowercased() {
            case "session": return .session(id: id)
            case "notification": return .notification(id: id)
            default: return .note(id: id)
            }
        case "notes":
            guard segments.count == 1 else { return nil }
            return .notesList
        case "createsession":
            guard segments.count == 1 else { return nil }
            return .createSession
        default:
            return nil
        }
    }

    /// `session`'s `messageID` never appears here — a URL is what a shortcut or widget persists
    /// and reopens months later, exactly the staleness this type's own doc comment already rules
    /// out for everything else. `messageID` only ever travels fresh, over an APNs payload this
    /// process just received or an in-app push while the notification centre is still on screen.
    public var url: URL? {
        switch self {
        case .session(let id, _): return URL(string: "pai://session/\(Self.escape(id))")
        case .note(let id): return URL(string: "pai://note/\(Self.escape(id))")
        case .notesList: return URL(string: "pai://notes")
        case .createSession: return URL(string: "pai://createsession")
        case .notification(let id): return URL(string: "pai://notification/\(Self.escape(id))")
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
