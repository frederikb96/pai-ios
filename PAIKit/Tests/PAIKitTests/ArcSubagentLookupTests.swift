import Foundation
import XCTest

@testable import PAIKit

final class ArcSubagentLookupTests: XCTestCase {

    private func session(id: String, claudeSessionId: String?, subagentName: String? = nil) -> Session {
        Session(
            id: id, sessionType: "home", status: .active, state: nil, blocker: nil, working: nil, title: nil,
            titleLocked: nil, initialMessage: nil, sessionTokens: 0, claudeSessionId: claudeSessionId,
            idleTimeoutMinutes: nil, effectiveIdleTimeoutMinutes: nil, cseId: nil, createdAt: nil, updatedAt: nil,
            lastActivityAt: nil, workingDir: nil, agent: nil, kind: nil, parentSessionId: nil,
            subagentName: subagentName, subagentType: nil, subagentDescription: nil, remoteControl: nil,
            discovered: nil, projectId: nil, phaseId: nil, projectName: nil
        )
    }

    // MARK: - resolveBoundSessionId

    /// The session the ARC view was opened from wins whenever IT is itself bound to the spec —
    /// the common case (reached from that session's own "Spec" action) — even when a different
    /// loaded session is also bound.
    func test_resolveBoundSessionId_prefersTheActiveSessionWhenItIsBound() {
        let active = session(id: "active", claudeSessionId: "conv-active")
        let other = session(id: "other", claudeSessionId: "conv-other")
        let resolved = ArcSubagentLookup.resolveBoundSessionId(
            specSessions: ["conv-active", "conv-other"], activeSessionId: "active", sessions: [active, other])
        XCTAssertEqual(resolved, "active")
    }

    /// The active session is loaded but NOT bound to this spec (the view was opened from a
    /// session running a different spec, or none) — falls back to scanning every other loaded
    /// session rather than giving up.
    func test_resolveBoundSessionId_fallsBackWhenActiveSessionIsNotBound() {
        let active = session(id: "active", claudeSessionId: "conv-unrelated")
        let bound = session(id: "bound", claudeSessionId: "conv-bound")
        let resolved = ArcSubagentLookup.resolveBoundSessionId(
            specSessions: ["conv-bound"], activeSessionId: "active", sessions: [active, bound])
        XCTAssertEqual(resolved, "bound")
    }

    func test_resolveBoundSessionId_nilActiveSession_scansEveryLoadedSession() {
        let bound = session(id: "bound", claudeSessionId: "conv-bound")
        let resolved = ArcSubagentLookup.resolveBoundSessionId(
            specSessions: ["conv-bound"], activeSessionId: nil, sessions: [bound])
        XCTAssertEqual(resolved, "bound")
    }

    /// The bound session was never loaded into this client at all (a deep link, a cold tab) —
    /// answers `nil` rather than guessing, so the caller can tell the reader it cannot resolve a
    /// badge tap rather than opening the wrong transcript.
    func test_resolveBoundSessionId_noLoadedSessionMatches_isNil() {
        let unrelated = session(id: "unrelated", claudeSessionId: "conv-unrelated")
        let resolved = ArcSubagentLookup.resolveBoundSessionId(
            specSessions: ["conv-bound"], activeSessionId: nil, sessions: [unrelated])
        XCTAssertNil(resolved)
    }

    // MARK: - findSubagentSession

    func test_findSubagentSession_matchesByNameNotId() {
        let subagent = session(id: "some-uuid", claudeSessionId: nil, subagentName: "arc-core")
        XCTAssertEqual(ArcSubagentLookup.findSubagentSession([subagent], named: "arc-core")?.id, "some-uuid")
        XCTAssertNil(ArcSubagentLookup.findSubagentSession([subagent], named: "some-uuid"))
    }

    // MARK: - findBoundSubagent (paging)

    /// `findBoundSubagent`'s `fetchPage` is `@Sendable`, so a call-recording test closure needs
    /// somewhere Sendable-safe to record into — an `actor`, matching `FakeArcSpecListApi`'s own
    /// shape above, rather than a captured local `var` a `@Sendable` closure cannot mutate.
    private actor CallRecorder {
        private(set) var cursors: [String?] = []
        func record(_ cursor: String?) {
            cursors.append(cursor)
        }
    }

    /// The name is not on the first page — proves the walk actually follows the cursor to a
    /// second page rather than trusting the first (default-sized) one alone.
    func test_findBoundSubagent_findsNameOnASecondPage() async throws {
        let firstPage = SessionsPage(
            sessions: [session(id: "a", claudeSessionId: nil, subagentName: "other")], nextCursor: "cursor-2")
        let secondPage = SessionsPage(
            sessions: [session(id: "b", claudeSessionId: nil, subagentName: "arc-core")], nextCursor: nil)
        let recorder = CallRecorder()

        let found = try await ArcSubagentLookup.findBoundSubagent(agentName: "arc-core") { cursor in
            await recorder.record(cursor)
            return cursor == nil ? firstPage : secondPage
        }

        XCTAssertEqual(found?.id, "b")
        let requestedCursors = await recorder.cursors
        XCTAssertEqual(requestedCursors, [nil, "cursor-2"])
    }

    /// The last page has no `nextCursor` and the name never appeared — stops rather than paging
    /// forever, and answers `nil`.
    func test_findBoundSubagent_exhaustsPagesWithoutAMatch_isNil() async throws {
        let onlyPage = SessionsPage(
            sessions: [session(id: "a", claudeSessionId: nil, subagentName: "someone-else")], nextCursor: nil)
        let recorder = CallRecorder()

        let found = try await ArcSubagentLookup.findBoundSubagent(agentName: "arc-core") { cursor in
            await recorder.record(cursor)
            return onlyPage
        }

        XCTAssertNil(found)
        let callCount = await recorder.cursors.count
        XCTAssertEqual(callCount, 1, "a page with no nextCursor must stop the walk after exactly one call")
    }
}
