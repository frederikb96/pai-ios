import Observation

/// Asks whichever transcript screen for a session is currently alive to jump to a message,
/// bypassing `Route` entirely.
///
/// `Route.session`'s `messageID` deliberately does not participate in equality (see that case's
/// own doc comment) — two pushes of the same session that differ only in where they jump to are
/// the same screen. That is right for identity, but it means replacing an already-open
/// `.session(id: X)` with `.session(id: X, messageID: 42)` is invisible to `NavigationStack`: the
/// path element reads as unchanged, so the destination is never rebuilt and the new `messageID`
/// never reaches `TranscriptCollectionViewController`, which only ever reads it once, at
/// construction (`initialJumpMessageID`). A tapped push notification for the session already on
/// screen would therefore silently do nothing.
///
/// This is the side channel that reaches the controller anyway — set up once when the controller
/// is created (`TranscriptCollectionViewController.observeJumpRequests()`), independent of
/// whether SwiftUI ever rebuilds its wrapping view. Callers only need to use it for a session
/// that is already open; the ordinary "open a session at a message" path still goes through
/// `Route.session`'s `messageID` and works exactly as before.
@MainActor
@Observable
public final class TranscriptJumpRequests {
    private var pending: [String: Int] = [:]

    public init() {}

    /// Ask the live screen for `sessionID`, if any, to jump to `messageID`.
    public func request(sessionID: String, messageID: Int) {
        pending[sessionID] = messageID
    }

    /// What `withObservationTracking` reads to subscribe to `sessionID`'s own entry — a plain
    /// property read inside a tracking closure registers the dependency whether it happens
    /// directly or, as here, through a method, so this stays the one place that reads `pending`.
    public func pendingMessageID(for sessionID: String) -> Int? {
        pending[sessionID]
    }

    /// Pops the pending jump for `sessionID`, if any — consumed at most once, so a later write
    /// for a *different* session (the same dictionary, tracked as a whole by `@Observable`) never
    /// re-triggers an observer that already handled its own.
    public func consume(sessionID: String) -> Int? {
        pending.removeValue(forKey: sessionID)
    }
}
