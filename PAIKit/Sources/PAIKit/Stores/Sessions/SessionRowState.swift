import Foundation

/// Swift port of the parts of `pai-cloud/web/src/utils/sessionState.ts` the session list needs.
/// `sessionHeaderTitle`/`resumeMayCollide` stay unported here — they belong to the chat header and
/// the row actions menu, neither of which reads through this store.

/// Which bucket a session's dot falls into — a display concept, not a color; `Theme` owns the
/// actual palette. A straight mapping from `DisplayState`, plus the legacy `SessionStatus` bucket
/// for a backend that predates it — see `dotState(for:)` below. There is no separate grey case
/// here any more: drivability (`SessionListDomain.isGrey`) governs the composer/Resume choice and
/// the row's label, never the dot's own colour — see that function's doc comment for why.
public enum SessionDotState: Sendable, Equatable {
    case starting, working, done, blocked, error, closed
    case legacyPending, legacyActive, legacyCompleted, legacyError, legacyInterrupted
}

extension SessionDotState {
    /// Whether the dot should pulse — `starting`/`blocked`/`error` and the legacy `active` all
    /// read as "something is happening"; everything else is settled.
    public var pulses: Bool {
        switch self {
        case .starting, .blocked, .error, .legacyActive: return true
        default: return false
        }
    }
}

public enum SessionListDomain {
    /// A straight mapping from `display_state` — the one field both clients paint a session's dot
    /// from (see `Session.displayState`'s doc comment). Nothing here re-derives anything from
    /// `state`, `discovered` or `kind`: that folding already happened once, on the backend. A
    /// backend that predates the field falls back to the legacy `status` badge rather than
    /// inventing a colour, matching the web's own `sessionDotColor`.
    public static func dotState(for session: Session) -> SessionDotState {
        if let displayState = session.displayState { return dotState(for: displayState) }
        return dotState(for: session.status)
    }

    public static func dotState(for state: DisplayState) -> SessionDotState {
        switch state {
        case .starting: return .starting
        case .working: return .working
        case .done: return .done
        case .blocked: return .blocked
        case .error: return .error
        case .closed: return .closed
        // A value this build predates falls back to the same bucket a closed session renders,
        // matching the web's own `default:` branch in `displayDotColor`.
        case .unrecognized: return .closed
        }
    }

    private static func dotState(for status: SessionStatus) -> SessionDotState {
        switch status {
        case .pending: return .legacyPending
        case .active: return .legacyActive
        case .completed: return .legacyCompleted
        case .error: return .legacyError
        case .interrupted: return .legacyInterrupted
        case .deleted, .unrecognized: return .closed
        }
    }

    /// True while this session is making progress: mid-turn, or parked on something that will
    /// wake it back up by itself. The spinner is shown in place of the dot for exactly this.
    ///
    /// Note what it deliberately no longer means. It is not "a subagent or a background shell is
    /// running" — a worker writing into the parent transcript is indistinguishable from the main
    /// agent working, so those counts drive the badges beside the token figure and nothing else.
    /// And it is not "the process has no live tmux" — a discovered session now reads this exactly
    /// the same way a launched one does, since `displayState` already folded its own hook signals
    /// in on the backend; there is no separate discovered-only path here any more.
    public static func isWorking(_ session: Session) -> Bool {
        session.displayState == .working
    }

    /// Whether PAI has a live process of its own for this session — the only thing that decides
    /// whether it can be typed into. `remote_control` deliberately plays no part: it records that
    /// the CONVERSATION registered with Remote Control at some point and never goes back to
    /// false, so it would stay true long after the terminal that set it is gone. A subagent is
    /// never drivable, whatever its state. A supervisor DOES have its own process, but is
    /// deliberately never drivable either — Freddy reads its verdicts, he never types into it.
    public static func isDrivable(_ session: Session) -> Bool {
        if session.kind == .subagent || session.kind == .supervisor { return false }
        guard let state = session.state else { return false }
        return state != .closed
    }

    /// Grey is a normal, frequent state — a session Freddy runs himself in a terminal, or one PAI
    /// closed when it went idle — not a fault.
    public static func isGrey(_ session: Session) -> Bool { !isDrivable(session) }

    /// The plain-English name for a `DisplayState` — what `sessionLabel` below shows once it has
    /// settled whether this session is grey. Swift port of `sessionState.ts`'s `displayLabel`.
    public static func displayLabel(_ state: DisplayState) -> String {
        switch state {
        case .starting: return "Starting…"
        case .working: return "Working…"
        case .done: return "Done"
        case .blocked: return "Waiting on you"
        case .error: return "Needs attention"
        case .closed: return "Closed"
        case let .unrecognized(raw): return raw
        }
    }

    /// The label next to a session's dot/spinner. Swift port of `sessionState.ts`'s
    /// `sessionLabel`: a subagent or supervisor names itself regardless of drivability, since
    /// neither has a `displayState` of its own worth reading; otherwise `displayState` supplies
    /// the label, with " · not driven by PAI" appended for a grey session that is not already
    /// showing `.closed` (which already says as much on its own).
    public static func sessionLabel(for session: Session) -> String {
        if session.kind == .subagent { return "Subagent" }
        if session.kind == .supervisor { return "Supervisor" }
        if let displayState = session.displayState {
            let label = displayLabel(displayState)
            return isGrey(session) && displayState != .closed ? "\(label) · not driven by PAI" : label
        }
        return isGrey(session) ? "Not driven by PAI" : ""
    }

    /// What to head a session's chat view with. A subagent is outside the phase-naming rule and
    /// its `title` is normally `nil`, so it falls back to `initial_message` or literally
    /// "Session" exactly like an ordinary session unless it has a name or type of its own to show
    /// first. Swift port of `sessionState.ts`'s `sessionHeaderTitle`.
    public static func sessionHeaderTitle(for session: Session) -> String {
        let own: String
        if session.kind == .subagent {
            own = session.subagentName ?? session.subagentType ?? session.title ?? session.initialMessage ?? "Session"
        } else {
            own = session.title ?? session.initialMessage ?? "Session"
        }
        return SessionListFormat.withProjectPrefix(session.projectName, own)
    }

    /// What the gated-secret-grant sheet names as the target it is about to unlock — title,
    /// session type and machine, so granting from a stale sheet is never ambiguous about which
    /// conversation receives it. Falls back to the raw session-type id and machine slug when the
    /// machine directory has not loaded yet or the row predates multi-agent.
    public static func secretGrantTarget(for session: Session, machines: [Machine]) -> String {
        let slug = session.agent ?? MachineStore.defaultMachineSlug
        let machine = machines.first { $0.slug == slug }
        let machineName = machine?.displayName ?? slug
        let typeName = machine?.sessionTypes.first { $0.id == session.sessionType }?.name ?? session.sessionType
        return "\(sessionHeaderTitle(for: session)) · \(typeName) on \(machineName)"
    }

    /// The claude.ai/code deep link for this session's Remote Control registration, or `nil`
    /// before one exists. Swift port of `claudeSession.ts`'s `claudeCodeUrl`.
    public static func claudeCodeUrl(cseId: String?) -> URL? {
        guard let cseId, !cseId.isEmpty else { return nil }
        let prefix = "cse_"
        let ulid = cseId.hasPrefix(prefix) ? String(cseId.dropFirst(prefix.count)) : cseId
        return URL(string: "https://claude.ai/code/session_\(ulid)")
    }
}
