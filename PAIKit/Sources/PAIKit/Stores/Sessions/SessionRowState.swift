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
    public static func dotState(for session: Session) -> SessionDotState {
        if isGrey(session) { return .grey }
        if let state = session.state { return dotState(for: state) }
        return dotState(for: session.status)
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
    /// a stale value. Not read by the list row itself — the report that mapped this screen flags
    /// it as worth having for the chat header, which reads through the same `Session`.
    public static func isWorking(_ session: Session) -> Bool {
        session.state == .ready && session.working == true
    }

    /// Whether PAI has a live process of its own for this session — the only thing that decides
    /// whether it can be typed into. `remote_control` deliberately plays no part: it records that
    /// the CONVERSATION registered with Remote Control at some point and never goes back to
    /// false, so it would stay true long after the terminal that set it is gone. A subagent is
    /// never drivable, whatever its state.
    public static func isDrivable(_ session: Session) -> Bool {
        if session.kind == .subagent { return false }
        guard let state = session.state else { return false }
        return state != .closed
    }

    /// Grey is a normal, frequent state — a session Freddy runs himself in a terminal, or one PAI
    /// closed when it went idle — not a fault.
    public static func isGrey(_ session: Session) -> Bool { !isDrivable(session) }
}
