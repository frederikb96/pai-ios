import Foundation

/// What ``TranscriptStore/locate(_:sessionId:retryLadder:fetchAround:)`` did to make a message
/// part of a session's loaded window.
public enum TranscriptLocateOutcome: Equatable, Sendable {
    /// Already loaded — nothing was fetched.
    case alreadyLoaded
    /// The page around it overlapped or abutted the window and was folded into it.
    case merged
    /// The page around it sat nowhere near the window and replaced it outright, so every row is
    /// freshly loaded and has never been measured.
    case replaced
    /// Not a message of this session, after every retry the caller allowed.
    case notFound
}

extension TranscriptStore {

    public func isLoaded(_ messageId: Int, sessionId: String) -> Bool {
        messages[sessionId]?.contains { $0.id == messageId } ?? false
    }

    /// `locate(id)` from the scrolling design: already loaded is a no-op; otherwise fetch the page
    /// around `messageId`, then merge it into the window when it overlaps or abuts it, or replace
    /// the window when it does not.
    ///
    /// `fetchAround` is handed the page size to ask for rather than choosing one, because the
    /// window's `hasOlder`/`hasNewer` are read off how full each half of that page came back.
    ///
    /// `retryLadder` turns a 404 from "gone" into "not ingested yet, try again" — a deep link's
    /// contract, since its target can arrive a moment after the link was generated. A hit the
    /// server itself just listed passes none: a 404 there means it vanished under a reingest. A
    /// fetch that throws is retried the same way, since it says nothing about the target either
    /// way.
    public func locate(
        _ messageId: Int, sessionId: String, retryLadder: [Duration] = [],
        fetchAround: (_ aroundId: Int, _ limit: Int) async throws -> MessagesAroundResult
    ) async -> TranscriptLocateOutcome {
        if isLoaded(messageId, sessionId: sessionId) { return .alreadyLoaded }

        let limit = Self.olderPageLimit
        for attempt in 0...retryLadder.count {
            switch try? await fetchAround(messageId, limit) {
            case .ok(let entries):
                guard let pageMin = entries.map(\.id).min(), let pageMax = entries.map(\.id).max() else {
                    return .notFound
                }
                let outcome: TranscriptLocateOutcome
                if Self.overlapsOrAbuts(window(for: sessionId), pageMin: pageMin, pageMax: pageMax) {
                    mergeWindow(sessionId: sessionId, entries: entries, aroundId: messageId, limit: limit)
                    outcome = .merged
                } else {
                    replaceWindow(sessionId: sessionId, entries: entries, aroundId: messageId, limit: limit)
                    outcome = .replaced
                }
                return isLoaded(messageId, sessionId: sessionId) ? outcome : .notFound
            case .notFound, nil:
                guard attempt < retryLadder.count else { return .notFound }
                try? await Task.sleep(for: retryLadder[attempt])
            }
        }
        return .notFound
    }

    /// Where a transcript opened at a deep link lands first — the linked message itself, once one
    /// attempt at locating it has put it in the window, so the first positioning the reader sees
    /// is the jump rather than the bottom followed by a jump. `nil` when that one attempt did not
    /// find it (not ingested yet, most likely): the open then lands wherever an ordinary open
    /// would, and the caller keeps retrying with the full ladder from there.
    ///
    /// Called right after the tail bootstrap and before anything is laid out, which is what makes
    /// the landing a restore rather than a second positioning mechanism: a restore target survives
    /// until the view can lay it out, while a scroll issued now would have no rows to land on.
    public func deepLinkLanding(
        for messageId: Int, sessionId: String,
        fetchAround: (_ aroundId: Int, _ limit: Int) async throws -> MessagesAroundResult
    ) async -> TranscriptRestoreTarget? {
        switch await locate(messageId, sessionId: sessionId, fetchAround: fetchAround) {
        case .alreadyLoaded, .merged, .replaced: return .deepLink(id: messageId)
        case .notFound: return nil
        }
    }
}
