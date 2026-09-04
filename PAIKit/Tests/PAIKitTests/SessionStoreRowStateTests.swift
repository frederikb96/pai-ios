import XCTest
@testable import PAIKit

/// `SessionListDomain`'s precedence rules — grey wins over `state`, `state` wins over legacy
/// `status` — are exactly the kind of thing a refactor could silently reorder. The
/// `isDrivable`/unrecognized-state interaction is the sharpest one: a state value this build does
/// not recognize must still read as drivable, matching how the web (no closed union at runtime)
/// treats an unrecognized string as merely "not the literal `'closed'`".
final class SessionStoreRowStateTests: XCTestCase {

    func testDrivableReadySessionIsNotGrey() {
        let session = SessionFixture.make(state: .ready)
        XCTAssertTrue(SessionListDomain.isDrivable(session))
        XCTAssertFalse(SessionListDomain.isGrey(session))
        XCTAssertEqual(SessionListDomain.dotState(for: session), .ready)
    }

    func testClosedSessionIsGreyDespiteHavingAState() {
        let session = SessionFixture.make(state: .closed)
        XCTAssertFalse(SessionListDomain.isDrivable(session))
        XCTAssertEqual(SessionListDomain.dotState(for: session), .grey)
    }

    func testSessionWithNoStateAtAllIsGrey() {
        let session = SessionFixture.make(state: nil)
        XCTAssertFalse(SessionListDomain.isDrivable(session))
        XCTAssertEqual(SessionListDomain.dotState(for: session), .grey)
    }

    /// A message typed at a discovered session has nowhere to go — PAI holds no process for it —
    /// regardless of how alive `presenceState` says it looks on screen.
    func testDiscoveredSessionStaysNotDrivableWhateverPresenceStateSays() {
        let session = SessionFixture.make(state: .closed, presenceState: .working, discovered: true)
        XCTAssertFalse(SessionListDomain.isDrivable(session))
    }

    /// A subagent is never drivable whatever its state — the row anatomy's grey dot must not
    /// depend on whether someone remembered to also null out `state` for one.
    func testSubagentIsGreyEvenWithAReadyState() {
        let session = SessionFixture.make(state: .ready, kind: .subagent)
        XCTAssertFalse(SessionListDomain.isDrivable(session))
        XCTAssertEqual(SessionListDomain.dotState(for: session), .grey)
    }

    /// The sharpest divergence risk in this file: an unrecognized state string is not `nil` and
    /// is not the literal `.closed`, so it reads as drivable — offering a composer for it is
    /// correct, not a bug, because the web (no closed union at runtime) would do the same.
    func testUnrecognizedStateStillReadsAsDrivable() {
        let session = SessionFixture.make(state: .unrecognized("future_state"))
        XCTAssertTrue(SessionListDomain.isDrivable(session))
        // The dot itself still falls back to the closed-looking bucket — display-only, and
        // distinct from drivability, which is why this assertion sits beside the one above
        // rather than being inferred from it.
        XCTAssertEqual(SessionListDomain.dotState(for: session), .closed)
    }

    func testGreyWinsOverALiveReadyStateWhenNotDrivable() {
        // A subagent reporting `ready` must never render the green "all is well" dot — grey is
        // supposed to win over everything, including a state that would otherwise look healthy.
        let session = SessionFixture.make(state: .ready, kind: .subagent)
        XCTAssertNotEqual(SessionListDomain.dotState(for: session), .ready)
        XCTAssertEqual(SessionListDomain.dotState(for: session), .grey)
    }

    /// A discovered session's `state` sits permanently `.closed` — there is no PAI process to
    /// poll — so `presenceState` is the only field that can tell it apart from one that is
    /// genuinely gone.
    func testDiscoveredSessionReadsPresenceStateInsteadOfItsPermanentlyClosedState() {
        let idle = SessionFixture.make(state: .closed, presenceState: .idle, discovered: true)
        let working = SessionFixture.make(state: .closed, presenceState: .working, discovered: true)
        let closed = SessionFixture.make(state: .closed, presenceState: .closed, discovered: true)
        let unknown = SessionFixture.make(state: .closed, presenceState: nil, discovered: true)

        XCTAssertEqual(SessionListDomain.dotState(for: idle), .ready)
        XCTAssertEqual(SessionListDomain.dotState(for: working), .ready)
        XCTAssertEqual(SessionListDomain.dotState(for: closed), .grey)
        XCTAssertEqual(SessionListDomain.dotState(for: unknown), .grey)
    }

    /// A stale `presence_state: .idle` left over from before PAI closed a session it actually
    /// launched must not turn that dot green — only a discovered session reads this field at all.
    func testNonDiscoveredSessionNeverReadsPresenceStateForItsDot() {
        let session = SessionFixture.make(state: .closed, presenceState: .idle, discovered: false)
        XCTAssertEqual(SessionListDomain.dotState(for: session), .grey)
    }

    func testLegacyStatusFallsBackOnlyWhenStateIsAbsent() {
        let withState = SessionFixture.make(status: .error, state: .ready)
        XCTAssertEqual(SessionListDomain.dotState(for: withState), .ready)

        let withoutState = SessionFixture.make(status: .error, state: nil)
        // No `state` at all reads as not drivable (grey) before the legacy status is ever
        // consulted for drivability — but the DOT still falls back to the legacy mapping, since
        // dot color and drivability are governed by different rules (see `SessionRowState.swift`).
        XCTAssertFalse(SessionListDomain.isDrivable(withoutState))
    }

    func testIsWorkingRequiresBothReadyAndWorkingTrue() {
        XCTAssertTrue(SessionListDomain.isWorking(SessionFixture.make(state: .ready, working: true)))
        XCTAssertFalse(SessionListDomain.isWorking(SessionFixture.make(state: .ready, working: false)))
        XCTAssertFalse(SessionListDomain.isWorking(SessionFixture.make(state: .ready, working: nil)))
        // A stale `working: true` reported outside `.ready` must not read as working — this is
        // the exact guard the report calls out: `worker_status` does not self-clear.
        XCTAssertFalse(SessionListDomain.isWorking(SessionFixture.make(state: .attention, working: true)))
    }

    /// `working` never fires for a discovered session (see `dotState(for:)`), so its spinner is
    /// read off `presenceState` instead.
    func testIsWorkingReadsPresenceStateForADiscoveredSession() {
        let working = SessionFixture.make(state: .closed, presenceState: .working, discovered: true)
        let idle = SessionFixture.make(state: .closed, presenceState: .idle, discovered: true)
        XCTAssertTrue(SessionListDomain.isWorking(working))
        XCTAssertFalse(SessionListDomain.isWorking(idle))
    }

    func testIsWorkingIgnoresPresenceStateForASessionPaiActuallyLaunched() {
        let session = SessionFixture.make(state: .closed, presenceState: .working, discovered: false)
        XCTAssertFalse(SessionListDomain.isWorking(session))
    }

    func testDotStatePulsesOnlyForInFlightStates() {
        XCTAssertTrue(SessionDotState.starting.pulses)
        XCTAssertTrue(SessionDotState.blocked.pulses)
        XCTAssertTrue(SessionDotState.attention.pulses)
        XCTAssertTrue(SessionDotState.legacyActive.pulses)
        XCTAssertFalse(SessionDotState.ready.pulses)
        XCTAssertFalse(SessionDotState.grey.pulses)
        XCTAssertFalse(SessionDotState.closed.pulses)
    }

    // MARK: - sessionLabel

    func testSessionLabelReadsWorkingAheadOfThePlainStateName() {
        let session = SessionFixture.make(state: .ready, working: true)
        XCTAssertEqual(SessionListDomain.sessionLabel(for: session), "Working…")
    }

    func testSessionLabelIsGreyAwareAndNamesSubagentDistinctlyFromAnOrdinarySession() {
        let subagent = SessionFixture.make(state: nil, kind: .subagent)
        XCTAssertEqual(SessionListDomain.sessionLabel(for: subagent), "Subagent")

        let ordinary = SessionFixture.make(state: nil, kind: .conversation)
        XCTAssertEqual(SessionListDomain.sessionLabel(for: ordinary), "Not driven by PAI")
    }

    func testSessionLabelFallsBackToThePlainStateNameWhenNotWorking() {
        XCTAssertEqual(SessionListDomain.sessionLabel(for: SessionFixture.make(state: .blocked)), "Waiting on you")
        XCTAssertEqual(SessionListDomain.sessionLabel(for: SessionFixture.make(state: .attention)), "Needs attention")
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
