import Foundation

/// Swift port of the parts of `pai-cloud/web/src/utils/sessionState.ts` the session list needs.
/// `sessionLabel`/`sessionHeaderTitle`/`resumeMayCollide` stay unported here — they belong to the
/// chat header and the row actions menu, neither of which reads through this store.

/// Which bucket a session's dot falls into — a display concept, not a color; `Theme` owns the
/// actual palette. Grey and the `.closed` bucket render the same, but are reached differently:
/// grey wins on drivability (see `SessionListDomain.isGrey`), `.closed` is reached only for a
/// drivable session whose `state` this build cannot recognize (`SessionState.unrecognized`) —
/// see `dotState(for:)` below.
public enum SessionDotState: Sendable, Equatable {
    case grey
    case starting, ready, blocked, attention, closed
    case legacyPending, legacyActive, legacyCompleted, legacyError, legacyInterrupted
}

extension SessionDotState {
    /// Whether the dot should pulse — `starting`/`blocked`/`attention` and the legacy `active`
    /// all read as "something is happening"; everything else, including grey, is settled.
    public var pulses: Bool {
        switch self {
        case .starting, .blocked, .attention, .legacyActive: return true
        default: return false
        }
    }
}

public enum SessionListDomain {
    /// Grey — not driven by PAI — wins over everything else, including a live `ready` transcript,
    /// because that is the whole point of the color: it never turns green just because the
    /// conversation happens to be going well without PAI's help. Otherwise prefers `state` when
    /// present, falling back to the legacy `status` enum.
    ///
    /// `state` sits permanently `.closed` for a session PAI never launched (`discovered`) since
    /// there is no process to poll, so it reads `presenceState` instead — the only field that
    /// can tell such a session apart from one that is genuinely gone. Scoped to exactly that
    /// case: a drivable session, and a non-discovered grey session, both still come from `state`
    /// alone, unchanged.
    public static func dotState(for session: Session) -> SessionDotState {
        if isGrey(session) {
            if session.discovered == true { return dotState(forPresence: session.presenceState) }
            return .grey
        }
        if let state = session.state { return dotState(for: state) }
        return dotState(for: session.status)
    }

    /// `.working` and `.idle` render identically (green, no pulse) — `isWorking` is what swaps
    /// the dot for a spinner, exactly as it does for a PAI-launched session.
    private static func dotState(forPresence presence: SessionPresenceState?) -> SessionDotState {
        switch presence {
        case .working, .idle: return .ready
        case .closed, .unrecognized, nil: return .grey
        }
    }

    public static func dotState(for state: SessionState) -> SessionDotState {
        switch state {
        case .starting: return .starting
        case .ready: return .ready
        case .blocked: return .blocked
        case .attention: return .attention
        case .closed: return .closed
        // A state value this build predates. `isDrivable` below already reads this as drivable
        // (matching the web, where an unrecognized string is merely not the literal `'closed'`);
        // the dot itself falls back to the same bucket a closed session renders, which is what
        // the web's own `default:` branch in `stateDotColor` does too.
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

    /// True while Claude is actively mid-turn on an otherwise-`ready` session. Deliberately gated
    /// on `state == .ready` rather than `working` alone: the agent's own `worker_status` does not
    /// self-clear, so trusting it outside a session already known to be up would spin forever on
    /// a stale value.
    ///
    /// A discovered session's `state` never reaches `.ready` at all (see `dotState(for:)`), so it
    /// reads `presenceState` instead — the same underlying signals, carried on the one field that
    /// still updates for a session PAI holds no process for.
    public static func isWorking(_ session: Session) -> Bool {
        if session.discovered == true { return session.presenceState == .working }
        return session.state == .ready && session.working == true
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

    /// The label next to a session's dot/spinner — grey-aware, and reading "Working…" ahead of
    /// the plain state label for the same reason the row's own spinner does: `isWorking` is a
    /// truer answer than the state name once a turn is actually running. Swift port of
    /// `sessionState.ts`'s `sessionLabel`.
    public static func sessionLabel(for session: Session) -> String {
        if isGrey(session) {
            if session.kind == .subagent { return "Subagent" }
            if session.kind == .supervisor { return "Supervisor" }
            return "Not driven by PAI"
        }
        if isWorking(session) { return "Working…" }
        guard let state = session.state else { return "" }
        switch state {
        case .starting: return "Starting…"
        case .ready: return "Ready"
        case .blocked: return "Waiting on you"
        case .attention: return "Needs attention"
        case .closed: return "Closed"
        case let .unrecognized(raw): return raw
        }
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

    /// The claude.ai/code deep link for this session's Remote Control registration, or `nil`
    /// before one exists. Swift port of `claudeSession.ts`'s `claudeCodeUrl`.
    public static func claudeCodeUrl(cseId: String?) -> URL? {
        guard let cseId, !cseId.isEmpty else { return nil }
        let prefix = "cse_"
        let ulid = cseId.hasPrefix(prefix) ? String(cseId.dropFirst(prefix.count)) : cseId
        return URL(string: "https://claude.ai/code/session_\(ulid)")
    }
}
