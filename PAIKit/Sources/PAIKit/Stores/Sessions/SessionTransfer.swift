import Foundation

/// The decisions behind the session menu's "Transfer to another machine…" entry, ported from
/// `SessionActionsMenu.tsx` so the rule and the wording are proven here rather than in a view.
public enum SessionTransfer {

    /// Whether the menu offers the action: an owner, on a deployment with somewhere to send it,
    /// for a conversation with a process of its own that has not already been sent. The server
    /// refuses the rest (a sandboxed session, a missing transcript) with its own message.
    public static func isAvailable(for session: Session, isOwner: Bool, machines: [Machine]) -> Bool {
        isOwner
            && MachineStore.hasMultipleAgents(machines)
            && session.kind != .subagent
            && !(session.kind.map(sessionKindsWithoutProcess.contains) ?? false)
            && !(session.kind.map(sessionKindsPodResident.contains) ?? false)
            && session.claudeSessionId != nil
            && session.transferredToSessionId == nil
    }

    /// Whether a process is running for the session right now — the case that is copied as a
    /// snapshot (`force: true`) rather than moved.
    public static func isLive(_ session: Session) -> Bool {
        session.state != nil && session.state != .closed
    }

    /// Every machine but the one the session already lives on. A row with no `agent` is the VM's.
    public static func targets(for session: Session, machines: [Machine]) -> [Machine] {
        let home = session.agent ?? MachineStore.defaultMachineSlug
        return machines.filter { $0.slug != home }
    }

    /// An offline machine is listed but cannot be chosen: both ends have to be up for the relay.
    public static func canChoose(_ machine: Machine, busy: Bool) -> Bool {
        machine.online && !busy
    }

    public static func rowTitle(for machine: Machine, live: Bool) -> String {
        (live ? "Copy snapshot to " : "Transfer to ") + machine.displayName
    }

    public static let liveWarning =
        "This session is running. Only a snapshot is copied: it keeps running here and the two copies will diverge, so one may be cut off at some point."

    public static func footer(live: Bool) -> String {
        "Moves the conversation's files to the other machine, where it continues as a new session. Both machines have to be online."
            + (live ? "" : " This one can no longer be resumed unless you transfer it back.")
    }
}
