import Foundation

/// What a flow card's coloured icon tile opens: the subagent transcript its leader's `g.name`
/// names, found among a bound session's own children. Mirrors `arcModel.ts`'s
/// `resolveBoundSessionId`/`findSubagentSession`/`findBoundSubagent` — pure logic, kept in
/// `PAIKit` rather than the view, so a refactor of the lookup is provable on Linux rather than
/// only by tapping a real card.
public enum ArcSubagentLookup {

    /// Which loaded session is "the bound session" whose children a badge tap should search —
    /// `specSessions` holds conversation uuids, never a PAI session id, so this is a join
    /// against whatever sessions this client already has loaded. Prefers the session the ARC
    /// view was opened from when THAT session is itself bound to the spec (the common case:
    /// reached from a session's own "Spec" action); falls back to a scan of every other loaded
    /// session. `nil` when the bound session was never loaded into this client at all — the
    /// caller treats that as "cannot resolve a badge tap", not as an error.
    public static func resolveBoundSessionId(
        specSessions: [String], activeSessionId: String?, sessions: [Session]
    ) -> String? {
        if let activeSessionId, let active = sessions.first(where: { $0.id == activeSessionId }),
            let claudeId = active.claudeSessionId, specSessions.contains(claudeId)
        {
            return activeSessionId
        }
        return sessions.first(where: { session in
            session.claudeSessionId.map(specSessions.contains) ?? false
        })?.id
    }

    /// A bound session's own child by name — never by id: `g` carries the agent's chosen NAME,
    /// and `g.agentId` is a transcript stem, not a session uuid.
    public static func findSubagentSession(_ subagents: [Session], named name: String) -> Session? {
        subagents.first(where: { $0.subagentName == name })
    }

    /// How many pages to walk before giving up — generous for any block a spec renders (a spec
    /// runs to hundreds of rows, not tens of thousands of subagents), and a hard stop against
    /// ever looping forever on a cursor that keeps coming back non-nil.
    static let maxPages = 20

    /// Finds a bound session's subagent by name, walking `fetchPage`'s own cursor rather than
    /// trusting the first (default-sized) page alone — the subagent search endpoint has no name
    /// filter, only substring matching over title/initial_message, so paging is the only correct
    /// way to reach a child past the first page. `nil` when the name is never found before the
    /// pages run out, in either sense (no more pages, or `maxPages` reached).
    ///
    /// `@Sendable` on `fetchPage`, matching `PushRegistrationStore.registerToken` and
    /// `VoiceRecordingSession.mintToken` — this is a plain nonisolated function, so a caller's
    /// closure literal crosses an isolation boundary to reach it and Swift 6 requires the
    /// closure TYPE be provably safe to send, not merely whatever it captures (`PaiApiClient`
    /// itself is already `Sendable`).
    public static func findBoundSubagent(
        agentName: String, fetchPage: @Sendable (String?) async throws -> SessionsPage
    ) async throws -> Session? {
        var cursor: String?
        for _ in 0..<maxPages {
            let page = try await fetchPage(cursor)
            if let found = findSubagentSession(page.sessions, named: agentName) { return found }
            guard let next = page.nextCursor else { return nil }
            cursor = next
        }
        return nil
    }
}
