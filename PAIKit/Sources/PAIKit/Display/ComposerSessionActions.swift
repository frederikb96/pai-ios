import Foundation

/// The session actions of the composer's plus menu, in the order they sit there: Cancel, Undo
/// send, Send now, Move to background, then Grant Secret Access. The web's plus menu lists the
/// same five the same way (`MessageInput.tsx`).
///
/// The order and the gating live here, as values, so a unit test proves them on Linux; the menu
/// itself (`ComposerActionMenu`) only draws what ``entries(hasSession:offersProcessActions:canGrantSecretAccess:)``
/// returns.
public enum ComposerSessionAction: String, CaseIterable, Sendable, Equatable {
    case cancel
    case undoSend
    case sendNow
    case moveToBackground
    case grantSecretAccess

    /// - Parameters:
    ///   - hasSession: Every action here acts on a session, so none exists before one does.
    ///   - offersProcessActions: `false` for a pod-resident (ultra-fast) session, which has no
    ///     process to hold a queue or run a command — send now and move to background do not
    ///     apply, and the pod answers `not_applicable` if asked.
    ///   - canGrantSecretAccess: the server's own verdict (`Session.secretGrantable`), not
    ///     derived from `hasSession`.
    public static func entries(
        hasSession: Bool, offersProcessActions: Bool, canGrantSecretAccess: Bool
    ) -> [ComposerSessionAction] {
        var result: [ComposerSessionAction] = []
        if hasSession {
            result += [.cancel, .undoSend]
            if offersProcessActions { result += [.sendNow, .moveToBackground] }
        }
        if canGrantSecretAccess { result.append(.grantSecretAccess) }
        return result
    }

    public var title: String {
        switch self {
        case .cancel: return "Cancel"
        case .undoSend: return "Undo send"
        case .sendNow: return "Send now"
        case .moveToBackground: return "Move to background"
        case .grantSecretAccess: return "Grant Secret Access"
        }
    }

    public var systemImage: String {
        switch self {
        case .cancel: return "stop.fill"
        case .undoSend: return "arrow.uturn.backward.circle"
        case .sendNow: return "bolt.fill"
        case .moveToBackground: return "arrow.down.to.line"
        case .grantSecretAccess: return "key"
        }
    }
}

extension SendNowResponse {
    /// The sentence a send-now answer is shown as — the same wording as the web.
    public var toastText: String {
        switch status {
        case .nothingQueued: return "Nothing queued"
        case .sent:
            return stillQueued.isEmpty
                ? "Sent now" : "Claude is holding the message — it will take it as soon as it can"
        case .refused:
            switch reason {
            case .blocked: return "Claude is waiting on a dialog — answer it first"
            case .promptHasDraft: return "Finish or clear the text in the terminal first"
            case .notRunning: return "The session is not running"
            case .paneUnreadable, .none: return "Could not read the terminal — try again"
            }
        case .unavailable: return "The VM agent is too old for this — update it"
        case .notApplicable: return "Not available for this kind of session"
        }
    }
}

extension MoveToBackgroundResponse {
    /// The sentence a move-to-background answer is shown as — the same wording as the web.
    public var toastText: String {
        switch status {
        case .moved: return "Moved to background"
        case .nothingRunning: return "Nothing running in the foreground"
        case .refused: return reason ?? "Claude would not move it to the background"
        case .unavailable: return "The VM agent is too old for this — update it"
        case .notApplicable: return "Not available for this kind of session"
        }
    }
}
