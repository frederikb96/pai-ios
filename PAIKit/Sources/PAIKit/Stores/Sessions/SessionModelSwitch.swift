import Foundation

/// What the session header's model badge shows and whether it opens the picker, ported from the
/// web's `ModelBadge.tsx`.
@MainActor
public enum SessionModelSwitch {
    /// Whether the session has a Claude process whose model can be switched.
    public static func canSwitch(_ session: Session) -> Bool {
        guard let kind = session.kind else { return true }
        return !sessionKindsWithoutProcess.contains(kind) && !sessionKindsPodResident.contains(kind)
    }

    /// The alias the next request (or launch) runs on: a switch nothing has answered from yet,
    /// else the stored alias. The live stream's answer wins as a unit once it has reported, since
    /// its `nil` pending is "nothing waiting", not "unknown".
    public static func currentAlias(_ session: Session, live: TranscriptStore.LiveSessionStatus?) -> String? {
        pendingAlias(session, live: live) ?? live?.model ?? session.model
    }

    /// The badge text: a pending switch, else the exact model the last reply came from, else the
    /// launch alias. `nil` when there is nothing to say and the badge is not a button; a button
    /// reads "Default" so the picker stays reachable.
    public static func badgeLabel(
        _ session: Session, live: TranscriptStore.LiveSessionStatus?
    ) -> String? {
        if let pending = pendingAlias(session, live: live) { return aliasLabel(pending) }
        if let label = ModelDisplay.label(forWireId: live?.liveModel ?? session.liveModel) { return label }
        if let alias = live?.model ?? session.model { return aliasLabel(alias) }
        return canSwitch(session) ? "Default" : nil
    }

    public static func aliasLabel(_ alias: String) -> String {
        CreateSessionStore.modelDisplayLabels[alias] ?? alias
    }

    private static func pendingAlias(_ session: Session, live: TranscriptStore.LiveSessionStatus?) -> String? {
        if let live { return live.pendingModel }
        return session.pendingModel
    }
}

/// The folder a session works in, as the header names it.
public enum WorkingFolder {
    /// The last path segment: `/home/me/code/app/` is `app`. A path with no segment (`/`) names
    /// itself.
    public static func name(of path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.last == "/" { trimmed = trimmed.dropLast() }
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed.isEmpty ? path : String(trimmed) }
        let last = trimmed[trimmed.index(after: slash)...]
        return last.isEmpty ? (trimmed.isEmpty ? path : String(trimmed)) : String(last)
    }
}
