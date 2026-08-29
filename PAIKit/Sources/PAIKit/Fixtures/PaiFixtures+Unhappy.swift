import Foundation

/// The paths a screenshot run never reaches by accident and a real backend produces only rarely
/// — empty pages, error bodies, and the terminal-status shapes of the write endpoints. This is
/// where a fixture earns its keep independently of any screen: nobody manually drives a session
/// into `close_error` to see how it looks.
extension PaiFixtures {

    // MARK: - Error bodies (`ApiError`, `{ detail: string }`)

    /// The one shape `request()` throws for in `client.ts` — every catch site in the app reduces
    /// to this string and toasts it.
    public static let errorSessionNotActive: String = #"""
        { "detail": "session_not_active" }
        """#

    /// The fallback `request()` synthesizes itself when a non-2xx body isn't valid JSON at all.
    public static let errorNonJsonFallback: String = #"""
        { "detail": "HTTP 500: Internal Server Error" }
        """#

    // MARK: - Empty pages

    public static let emptySessions: String = "[]"
    public static let emptyMessages: String = "[]"
    public static let emptyDrafts: String = "[]"
    public static let emptyAgents: String = "[]"
    public static let emptySearchResults: String = "[]"

    // MARK: - Write-endpoint status variants

    /// `POST /api/session/{id}/cancel`.
    public static let cancelResponse: String = #"""
        { "status": "cancelled" }
        """#

    /// `POST /api/session/{id}/close` — the pane was already gone, so the tmux kill itself
    /// failed. Distinct from `already_closed`, which is not an error.
    public static let closeResponseError: String = #"""
        { "status": "close_error", "detail": "tmux session already gone" }
        """#

    public static let closeResponseAlreadyClosed: String = #"""
        { "status": "already_closed" }
        """#

    /// `DELETE /api/session/{id}`.
    public static let deleteResponseAlreadyDeleted: String = #"""
        { "status": "already_deleted" }
        """#

    /// `POST /api/session/{id}/resume` — refused, because a subagent has no conversation uuid of
    /// its own to resume.
    public static let resumeResponseRefused: String = #"""
        { "status": "refused", "detail": "subagents have no conversation of their own to resume" }
        """#

    /// `POST /api/session/{id}/blocker/answer` — the session cleared its blocker before the
    /// answer arrived (a race the UI has to tolerate, not treat as a failure).
    public static let answerBlockerNoBlocker: String = #"""
        { "status": "no_blocker" }
        """#
}
