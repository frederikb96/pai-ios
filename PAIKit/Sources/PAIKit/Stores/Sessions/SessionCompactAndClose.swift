import Foundation

/// The session menu's "Compact & close" and "Close & delete" entries: when each is offered, and
/// what the no-memory wording says. The rules mirror the web's `SessionActionsMenu`.
public enum SessionCompactAndClose {
    /// Whether the menu offers "Compact & close": a live conversation with a Claude process of its
    /// own. Pod-resident sessions have no `/compact`, a Hermes model would be handed the command as
    /// plain text, and compacting a no-memory session is pointless because it is deleted on close.
    public static func isAvailable(for session: Session) -> Bool {
        guard session.state != nil, session.state != .closed else { return false }
        if session.kind.map(sessionKindsWithoutProcess.contains) ?? false { return false }
        if session.kind.map(sessionKindsPodResident.contains) ?? false { return false }
        if let model = session.model, SessionModelInfo.engine(forId: model) == SessionModelInfo.hermesEngine {
            return false
        }
        return !session.isNoMemory
    }

    public static let closeAndDeleteTitle = "Close & delete?"
    public static let closeAndDeleteMessage =
        "This is a no-memory session: closing it deletes the whole conversation, and it cannot be resumed."
    public static let compactingToast = "Compacting, then closing…"
}

/// The no-memory switch's own wording, shown by the model picker's info sheet.
public enum NoMemoryCopy {
    public static let toggleLabel = "No memory"
    public static let infoTitle = "No memory"
    public static let infoParagraphs = [
        "A no-memory session reads no PAI memory and sits in no project or phase. Nothing in it is summarised, and the whole conversation is deleted once it is closed."
    ]
    /// The composer's text for an ended no-memory session, which cannot be resumed.
    public static let endedComposerText = "This no-memory session has ended and is being deleted."
}
