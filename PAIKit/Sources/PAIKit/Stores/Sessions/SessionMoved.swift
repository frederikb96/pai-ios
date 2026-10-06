import Foundation

/// What a conversation that was transferred to another machine shows where it used to be: a pill
/// on its list row, a banner above its transcript and a composer that points at the new copy.
/// Ported from the web's moved marker so the wording and the rule live here rather than in views.
public enum SessionMoved {

    /// Whether the session was moved: `transferred_to_session_id` is the only signal, and it is
    /// set for a move and never for a snapshot copy.
    public static func isMoved(_ session: Session) -> Bool {
        session.transferredToSessionId != nil
    }

    /// The machine the conversation went to. The target's own `agent` names it when the target is
    /// in the loaded list; a target outside every loaded page falls back to the one machine that
    /// is not the source's own, and to a generic phrase when that is ambiguous.
    public static func machineName(for session: Session, target: Session?, machines: [Machine]) -> String {
        if let slug = target.map({ $0.agent ?? MachineStore.defaultMachineSlug }),
            let machine = machines.first(where: { $0.slug == slug })
        {
            return machine.displayName
        }
        let others = SessionTransfer.targets(for: session, machines: machines)
        return others.count == 1 ? others[0].displayName : "another machine"
    }

    /// The list row's pill; `nil` for a session that was not moved.
    public static func pillText(for session: Session, target: Session?, machines: [Machine]) -> String? {
        guard isMoved(session) else { return nil }
        return "Moved to " + machineName(for: session, target: target, machines: machines)
    }

    /// The banner above the transcript; the time is omitted when the session carries none.
    public static func bannerText(
        for session: Session, target: Session?, machines: [Machine],
        timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String? {
        guard isMoved(session) else { return nil }
        let name = machineName(for: session, target: target, machines: machines)
        guard let movedAt = session.transferredAt.flatMap(IsoTimestamp.date(from:)) else {
            return "This conversation moved to \(name)."
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "This conversation moved to \(name) on \(formatter.string(from: movedAt))."
    }

    /// What the disabled composer says in place of an input.
    public static func composerText(for session: Session, target: Session?, machines: [Machine]) -> String? {
        guard isMoved(session) else { return nil }
        return "Moved to \(machineName(for: session, target: target, machines: machines)) — open it there"
    }
}
