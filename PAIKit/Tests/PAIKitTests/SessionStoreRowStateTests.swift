import XCTest
@testable import PAIKit

/// `SessionListDomain.dotState(for:)` is now a straight mapping from `displayState`, entirely
/// separate from `isDrivable`/`isGrey` (`state`/`kind`-driven, and unchanged by this file's own
/// history) — the two used to be entangled (grey overrode the dot), which is exactly what this
/// suite now asserts is no longer true: a non-drivable session still gets a real, coloured dot
/// whenever the backend reports one.
final class SessionStoreRowStateTests: XCTestCase {

    func testDrivableReadySessionIsNotGrey() {
        let session = SessionFixture.make(state: .ready, displayState: .done)
        XCTAssertTrue(SessionListDomain.isDrivable(session))
        XCTAssertFalse(SessionListDomain.isGrey(session))
        XCTAssertEqual(SessionListDomain.dotState(for: session), .done)
    }

    func testClosedSessionIsNotDrivableDespiteHavingAState() {
        let session = SessionFixture.make(state: .closed)
        XCTAssertFalse(SessionListDomain.isDrivable(session))
    }

    func testSessionWithNoStateAtAllIsNotDrivable() {
        let session = SessionFixture.make(state: nil)
        XCTAssertFalse(SessionListDomain.isDrivable(session))
    }

    /// A message typed at a discovered session has nowhere to go — PAI holds no process for it —
    /// regardless of how alive `displayState` says it looks on screen.
    func testDiscoveredSessionStaysNotDrivableWhateverDisplayStateSays() {
        let session = SessionFixture.make(state: .closed, displayState: .working, discovered: true)
        XCTAssertFalse(SessionListDomain.isDrivable(session))
    }

    /// A subagent is never drivable whatever its state.
    func testSubagentIsNotDrivableEvenWithAReadyState() {
        let session = SessionFixture.make(state: .ready, kind: .subagent)
        XCTAssertFalse(SessionListDomain.isDrivable(session))
    }

    /// A supervisor DOES have its own live process — unlike a subagent, `isDrivable` cannot lean
    /// on "no process at all" for it, so this is the one case a refactor could plausibly drop.
    func testSupervisorIsNotDrivableEvenWithAReadyState() {
        let session = SessionFixture.make(state: .ready, kind: .supervisor)
        XCTAssertFalse(SessionListDomain.isDrivable(session))
    }

    /// The sharpest divergence risk in this file: an unrecognized state string is not `nil` and
    /// is not the literal `.closed`, so it reads as drivable — offering a composer for it is
    /// correct, not a bug, because the web (no closed union at runtime) would do the same.
    func testUnrecognizedStateStillReadsAsDrivable() {
        let session = SessionFixture.make(state: .unrecognized("future_state"))
        XCTAssertTrue(SessionListDomain.isDrivable(session))
    }

    /// The dot no longer knows anything about drivability at all — a subagent reporting a real
    /// `displayState` gets exactly that colour, same as any other session. Grey is now purely a
    /// label/composer concept (`isGrey`), never the dot's own colour — see `SessionRowState.swift`.
    func testASubagentsDotStillReflectsItsOwnDisplayStateDespiteBeingUndrivable() {
        let session = SessionFixture.make(state: .ready, displayState: .done, kind: .subagent)
        XCTAssertFalse(SessionListDomain.isDrivable(session))
        XCTAssertEqual(SessionListDomain.dotState(for: session), .done)
    }

    /// A discovered session now gets a real dot from its own hook signals, folded into
    /// `displayState` on the backend — it is no longer forced grey just because `state` sits
    /// permanently `.closed` for it.
    func testDiscoveredSessionGetsARealDotFromDisplayState() {
        let working = SessionFixture.make(state: .closed, displayState: .working, discovered: true)
        let done = SessionFixture.make(state: .closed, displayState: .done, discovered: true)
        let closed = SessionFixture.make(state: .closed, displayState: .closed, discovered: true)

        XCTAssertEqual(SessionListDomain.dotState(for: working), .working)
        XCTAssertEqual(SessionListDomain.dotState(for: done), .done)
        XCTAssertEqual(SessionListDomain.dotState(for: closed), .closed)
    }

    /// An absent `displayState` reads as closed, never as the legacy `status` badge.
    ///
    /// The badge fallback painted a closed session GREEN whenever its status happened to be
    /// `completed` — a dot contradicting its own "Not driven by PAI" label, and visible in the
    /// shipped fixtures. `Session.displayState`'s own doc comment and the web both say closed.
    func testDotStateReadsAnAbsentDisplayStateAsClosed() {
        let withDisplayState = SessionFixture.make(status: .error, displayState: .done)
        XCTAssertEqual(SessionListDomain.dotState(for: withDisplayState), .done)

        for status in [SessionStatus.completed, .error, .active, .pending, .interrupted] {
            let withoutDisplayState = SessionFixture.make(status: status, displayState: nil)
            XCTAssertEqual(
                SessionListDomain.dotState(for: withoutDisplayState), .closed,
                "status \(status) must not colour a session whose display state is unknown"
            )
        }
    }

    /// A value this build predates falls back to the same bucket a closed session renders,
    /// matching the web's own `default:` branch.
    func testUnrecognizedDisplayStateFallsBackToTheClosedBucket() {
        let session = SessionFixture.make(displayState: .unrecognized("future_state"))
        XCTAssertEqual(SessionListDomain.dotState(for: session), .closed)
    }

    func testIsWorkingIsAStraightMappingFromDisplayState() {
        XCTAssertTrue(SessionListDomain.isWorking(SessionFixture.make(displayState: .working)))
        XCTAssertFalse(SessionListDomain.isWorking(SessionFixture.make(displayState: .done)))
        XCTAssertFalse(SessionListDomain.isWorking(SessionFixture.make(displayState: nil)))
    }

    /// The one case a refactor could plausibly regress: `isWorking` used to special-case a
    /// discovered session (reading `presenceState` instead of `state`/`working`). That whole
    /// branch is gone now — a discovered session's spinner comes from the exact same field.
    func testIsWorkingNeedsNoSpecialCaseForADiscoveredSession() {
        let session = SessionFixture.make(state: .closed, displayState: .working, discovered: true)
        XCTAssertTrue(SessionListDomain.isWorking(session))
    }

    func testDotStatePulsesOnlyForInFlightStates() {
        XCTAssertTrue(SessionDotState.starting.pulses)
        XCTAssertTrue(SessionDotState.blocked.pulses)
        XCTAssertTrue(SessionDotState.error.pulses)
        XCTAssertTrue(SessionDotState.legacyActive.pulses)
        XCTAssertFalse(SessionDotState.working.pulses)
        XCTAssertFalse(SessionDotState.done.pulses)
        XCTAssertFalse(SessionDotState.closed.pulses)
    }

    // MARK: - sessionLabel

    func testSessionLabelReadsDisplayStateDirectly() {
        XCTAssertEqual(SessionListDomain.sessionLabel(for: SessionFixture.make(displayState: .working)), "Working…")
        XCTAssertEqual(
            SessionListDomain.sessionLabel(for: SessionFixture.make(displayState: .blocked)), "Waiting on you")
        XCTAssertEqual(
            SessionListDomain.sessionLabel(for: SessionFixture.make(displayState: .error)), "Needs attention")
    }

    func testSessionLabelNamesSubagentAndSupervisorRegardlessOfDisplayState() {
        let subagent = SessionFixture.make(state: nil, displayState: .done, kind: .subagent)
        XCTAssertEqual(SessionListDomain.sessionLabel(for: subagent), "Subagent")

        let supervisor = SessionFixture.make(state: nil, displayState: .done, kind: .supervisor)
        XCTAssertEqual(SessionListDomain.sessionLabel(for: supervisor), "Supervisor")
    }

    /// A grey (not drivable) session's label appends the "not driven by PAI" suffix — unless
    /// `displayState` is already `.closed`, which says as much on its own.
    func testSessionLabelAppendsNotDrivenByPaiForAGreySessionUnlessAlreadyClosed() {
        let greyWorking = SessionFixture.make(state: .closed, displayState: .working, discovered: true)
        XCTAssertEqual(SessionListDomain.sessionLabel(for: greyWorking), "Working… · not driven by PAI")

        let greyClosed = SessionFixture.make(state: .closed, displayState: .closed, discovered: true)
        XCTAssertEqual(SessionListDomain.sessionLabel(for: greyClosed), "Closed")
    }

    func testSessionLabelWithNoDisplayStateFallsBackToGreyOrEmpty() {
        let grey = SessionFixture.make(state: nil, displayState: nil)
        XCTAssertEqual(SessionListDomain.sessionLabel(for: grey), "Not driven by PAI")

        let drivable = SessionFixture.make(state: .ready, displayState: nil)
        XCTAssertEqual(SessionListDomain.sessionLabel(for: drivable), "")
    }

    // MARK: - sessionHeaderTitle

    func testSessionHeaderTitlePrefersTitleThenInitialMessageThenLiteralSession() {
        let titled = SessionFixture.make(title: "Renamed", initialMessage: "hi")
        XCTAssertEqual(SessionListDomain.sessionHeaderTitle(for: titled), "Renamed")

        let untitled = SessionFixture.make(title: nil, initialMessage: "hi there")
        XCTAssertEqual(SessionListDomain.sessionHeaderTitle(for: untitled), "hi there")

        let bare = SessionFixture.make(title: nil, initialMessage: nil)
        XCTAssertEqual(SessionListDomain.sessionHeaderTitle(for: bare), "Session")
    }

    /// A subagent's own name/type stand ahead of `title`/`initial_message` in the fallback chain
    /// — the one place this diverges from an ordinary session's `sessionHeaderTitle`.
    func testSessionHeaderTitlePrefersSubagentNameOverTitleForASubagent() {
        let named = SessionFixture.make(
            title: "some title", initialMessage: "hi", kind: .subagent, subagentName: "Aria",
            subagentType: "general-purpose"
        )
        XCTAssertEqual(SessionListDomain.sessionHeaderTitle(for: named), "Aria")

        let typedOnly = SessionFixture.make(
            title: "some title", kind: .subagent, subagentName: nil, subagentType: "Explore"
        )
        XCTAssertEqual(SessionListDomain.sessionHeaderTitle(for: typedOnly), "Explore")
    }

    func testSessionHeaderTitleCarriesTheProjectPrefix() {
        let session = SessionFixture.make(title: "Fix the alerting rule", projectName: "SOCCloud")
        XCTAssertEqual(SessionListDomain.sessionHeaderTitle(for: session), "SOCCloud : Fix the alerting rule")
    }

    // MARK: - secretGrantTarget

    private func makeMachine(slug: String, displayName: String, sessionTypes: [SessionType] = []) -> Machine {
        Machine(
            slug: slug, displayName: displayName, online: true, lastSeenAt: nil, ingestEnabled: true,
            capabilities: Machine.Capabilities(fastSessions: false, reboot: false, shell: false),
            sessionTypes: sessionTypes
        )
    }

    func testSecretGrantTargetNamesTitleTypeAndMachine() {
        let session = SessionFixture.make(
            sessionType: "claude", title: "Fix the alerting rule", agent: "laptop")
        let machines = [
            makeMachine(slug: "vm", displayName: "The VM"),
            makeMachine(
                slug: "laptop", displayName: "Freddy's Laptop",
                sessionTypes: [SessionType(id: "claude", name: "Claude Code", icon: "terminal")]),
        ]
        XCTAssertEqual(
            SessionListDomain.secretGrantTarget(for: session, machines: machines),
            "Fix the alerting rule · Claude Code on Freddy's Laptop"
        )
    }

    /// No `agent` on the row falls back to the VM's own slug — every session before multi-agent
    /// existed was one. An unknown session type or an empty/not-yet-loaded machine directory falls
    /// back to the raw id/slug rather than showing nothing.
    func testSecretGrantTargetFallsBackToRawIdsWhenTheMachineDirectoryHasNothingToOffer() {
        let session = SessionFixture.make(sessionType: "custom-type", title: "Untitled work", agent: nil)
        XCTAssertEqual(
            SessionListDomain.secretGrantTarget(for: session, machines: []),
            "Untitled work · custom-type on vm"
        )
    }

    // MARK: - claudeCodeUrl

    func testClaudeCodeUrlStripsTheCsePrefix() {
        XCTAssertEqual(
            SessionListDomain.claudeCodeUrl(cseId: "cse_01ABCXYZ")?.absoluteString,
            "https://claude.ai/code/session_01ABCXYZ"
        )
    }

    func testClaudeCodeUrlIsNilWithoutACseId() {
        XCTAssertNil(SessionListDomain.claudeCodeUrl(cseId: nil))
        XCTAssertNil(SessionListDomain.claudeCodeUrl(cseId: ""))
    }
}
