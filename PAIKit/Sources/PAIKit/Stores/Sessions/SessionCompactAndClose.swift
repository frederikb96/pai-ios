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
        "This is a no-memory session. Closing it deletes the conversation for good, and it cannot be resumed."
}

/// The no-memory switch's own wording, shown by the model picker's info sheet.
public enum NoMemoryCopy {
    public static let toggleLabel = "No memory"
    public static let infoTitle = "No memory"
    public static let infoParagraphs = [
        "A no-memory session leaves nothing behind in PAI. It gets no project or phase, no summaries are written, no memories are extracted from it and it is not named after what you talk about.",
        "While it is open you see the conversation as usual. When you close it, the conversation is deleted from PAI and from the machine it ran on, and it cannot be resumed afterwards.",
        "The session is also told not to write PAI memory, notes, skills or Claude's own auto memory, and not to read PAI memory. That part is an instruction, not a lock.",
        "Backups that already ran, and notifications already on your phone, keep what they had.",
    ]
    public static let hermesNote = "Not available with a Hermes model."
}
