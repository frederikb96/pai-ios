import Foundation

/// Decides when a notification for the open session counts as seen. The session being open is not
/// enough: a phone left on a session, or an app coming back to the front, says nothing about
/// whether the reader is looking at it. A notification is cleared at once only while the reader
/// is engaged — the app is active and real input happened within `engagedWindow` — and otherwise
/// waits for the next input.
///
/// Reaching a session on purpose needs no path of its own: the tap that opened it is the input
/// that makes the reader engaged. A route with no tap in the app (a banner tapped outside it, a
/// widget, a shortcut) reports itself through `noteActivity()`.
@MainActor
public final class SessionAttention {
    /// How long after the last input the reader still counts as engaged.
    public static let engagedWindow: TimeInterval = 20

    private let now: () -> Date
    private var lastActivity: Date?
    private var heldSessionId: String?
    private var appIsActive = true

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Whether the app is in front. Leaving it forgets the last input, so returning to the front
    /// is never read as activity and an input from before the absence never counts after it.
    public func setAppActive(_ active: Bool) {
        appIsActive = active
        if !active { lastActivity = nil }
    }

    /// Whether `sessionId`'s notifications are to be marked read now. When the reader is not
    /// engaged this returns `false` and holds the request for the next `noteActivity()`.
    public func shouldClearNow(_ sessionId: String) -> Bool {
        if isEngaged {
            if heldSessionId == sessionId { heldSessionId = nil }
            return true
        }
        heldSessionId = sessionId
        return false
    }

    /// Real input in the app's windows. Returns the session whose held request this releases, if
    /// any; the caller marks it read when it is still the open one.
    @discardableResult
    public func noteActivity() -> String? {
        lastActivity = now()
        guard appIsActive else { return nil }
        defer { heldSessionId = nil }
        return heldSessionId
    }

    private var isEngaged: Bool {
        guard appIsActive, let lastActivity else { return false }
        return now().timeIntervalSince(lastActivity) < Self.engagedWindow
    }
}
