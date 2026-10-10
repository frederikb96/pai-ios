import Foundation
import Observation

/// A new session that is meant to become a call the moment it exists.
///
/// A one-shot side channel rather than a field on ``Route/createSession``, for the same reason
/// ``NoteCreationFocus`` is one: a navigation path is restorable from disk on relaunch, and a
/// route that remembered "this one was going to be a call" would turn a cold launch weeks later
/// into an unasked-for recording. The intent belongs to the single navigation that follows the
/// tap, and to nothing else.
///
/// There is no session id here because there is no session yet. Creating one requires a first
/// message — the backend refuses an empty one — so a call cannot be opened first and filled in
/// afterwards. What happens instead: the new-session
/// screen comes up with the microphone already live, the first prompt is spoken into it, and the
/// session that send creates is the one the call then binds to.
@MainActor
public final class CallModeLaunchRequest {
    public static let shared = CallModeLaunchRequest()

    private var armed = false

    public init() {}

    /// Called by whatever is about to navigate to the new-session screen.
    public func arm() {
        armed = true
    }

    /// True at most once per ``arm()``. Consumed either way, so a second appearance of the same
    /// screen — a rotation, a return from the photo picker — never re-arms the microphone.
    public func consume() -> Bool {
        defer { armed = false }
        return armed
    }

    /// The session whose composer should open call mode the moment it mounts, if one is waiting.
    ///
    /// Why not simply push `Route.callMode` from the screen that created the session: that screen
    /// is a sheet, and it is dismissing at exactly that moment. A presentation requested from
    /// behind a dismissing sheet is dropped silently — the same trap `CreateSessionView` already
    /// documents for a plain push — and the failure here would be a call that never opens on a
    /// session that was created for one. Handing the request to the composer instead means the
    /// call is presented by the one piece of code that already presents it correctly, from a
    /// screen that is fully on top by the time it runs.
    private var pendingCallSessionID: String?

    /// Called with the id of a session that has just been created for a call.
    public func openCall(forSession id: String) {
        pendingCallSessionID = id
    }

    /// Whether `id` is the session a call was asked for — true at most once, and only for that
    /// session. Consumed either way, so returning to a transcript later never reopens a call.
    public func consumeOpenCall(forSession id: String) -> Bool {
        guard pendingCallSessionID == id else { return false }
        pendingCallSessionID = nil
        return true
    }

    /// Withdraws a request that will not be acted on — the screen was dismissed without sending,
    /// or the microphone could not be reserved. Without this an abandoned request would sit
    /// waiting and turn the *next* new session into a call nobody asked for.
    public func cancel() {
        armed = false
        pendingCallSessionID = nil
    }
}

/// The one moment in a new session's life that the new-session screen cannot see for itself.
///
/// A send from that screen does not wait for the network — it hands the message to
/// ``OutboxStore`` and returns — so the session it creates arrives later, on the outbox's own
/// worker, with no awaited call to return it to. ``createdSessionID`` is how that id reaches the
/// screen. The screen is deliberately the one that opens it: a push made from anywhere else
/// would be a push from behind a dismissing sheet, which iOS drops silently.
///
/// One-shot, for the reason ``CallModeLaunchRequest`` is: a navigation path survives a relaunch
/// and an intent must not, or a cold launch weeks later opens a screen nobody asked for.
@MainActor
@Observable
public final class NewSessionHandoff {
    public static let shared = NewSessionHandoff()

    /// The session a send composed on the new-session screen has just created, for as long as
    /// that screen has not yet acted on it. Set unconditionally when a create lands: a screen
    /// that is no longer on top simply never observes it, which is the same "do not yank the
    /// reader somewhere they have moved on from" rule the web applies by only following while
    /// its own new-session view is still showing.
    public private(set) var createdSessionID: String?

    public init() {}

    public func created(sessionID: String) {
        createdSessionID = sessionID
    }

    /// True at most once per ``created(sessionID:)``, and only for a screen that is there to take
    /// it. Consumed either way.
    public func consumeCreated() -> String? {
        defer { createdSessionID = nil }
        return createdSessionID
    }

    /// Drops a created session nobody opened — the new-session screen's own teardown. Without it
    /// a send that landed just as the screen was dismissed would fire against the next visit to
    /// that screen instead, opening a session composed minutes ago.
    public func withdrawCreated() {
        createdSessionID = nil
    }
}

/// A notes index that should come up with its filter field focused and the keyboard open.
///
/// Same one-shot shape and the same reason: `Route.notes` is restorable, and a restored index
/// that raises the keyboard by itself is a screen that cannot be read.
@MainActor
public final class NotesFilterFocus {
    public static let shared = NotesFilterFocus()

    private var armed = false

    public init() {}

    public func arm() {
        armed = true
    }

    public func consume() -> Bool {
        defer { armed = false }
        return armed
    }
}
