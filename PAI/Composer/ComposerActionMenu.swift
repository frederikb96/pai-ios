import PAIKit
import SwiftUI

/// The plus button's menu — a native `Menu`, matching the "must feel native" constraint directly
/// rather than porting the web's absolutely-positioned popover. Item order mirrors the web's plus
/// menu (`MessageInput.tsx`). `Cancel` needs only a session to exist; `Grant Secret Access` needs
/// the server to say this particular one is grantable — the two are gated separately rather than
/// both riding `hasSession`.
struct ComposerActionMenu: View {
    var hasSession: Bool
    /// Only the new-session screen offers this — an existing session's composer never does,
    /// since there is nothing left for it to start (the ElevenLabs-backed local call mode this
    /// once opened is gone; see this screen's own `startCallAfterSend`).
    var offersStartCallAfterSend: Bool = false
    /// Server-computed (`Session.secretGrantable`), not derived from `hasSession` — a session can
    /// exist and still have nothing to grant against (sandboxed, no live conversation), and
    /// re-deriving that predicate here would drift from what the grant route itself checks.
    var canGrantSecretAccess: Bool
    /// The new-session screen's grant, armed before the session exists: `nil` where it is not
    /// offered (an existing session's composer), otherwise whether one is armed right now —
    /// which decides whether the entry arms one or takes it back.
    var pregrantArmed: Bool? = nil
    var onTogglePregrant: () -> Void = {}
    /// Only when the server is holding a different earlier text than what's on screen — two
    /// devices never type at once, so the last writer wins, and this is how the loser gets its
    /// words back. Mirrors the web's own gate in `MessageInput.tsx`.
    var canRestorePreviousText: Bool
    /// Whether this menu is one of the three doors onto the voice screen. The new-session
    /// composer is not: a session does not exist yet for a call to be in, and navigating away
    /// mid-creation would abandon the message being written.
    var offersComputer: Bool = false
    /// Whether the live call is inside *this* session. The composer of the session a call is
    /// actually in is where the user is most likely to be looking when they want to get back to it,
    /// so that entry says so rather than reading like an offer to start a second call.
    var isOnTheCall: Bool = false
    /// Whether a call is running at all, anywhere.
    var isCallLive: Bool = false
    var onComputer: () -> Void = {}
    /// Opens a call inside THIS session, rather than reaching Computer and asking it to connect
    /// one. Offered only while no call is running: the phone has one call, so a second door into
    /// a different destination while one is live would promise something it cannot do.
    var onCallThisSession: () -> Void = {}
    /// False for an ultra-fast session or draft, which has no attachment path on the pod worker
    /// — the backend 400s a file on one regardless, but hiding the entries here is what keeps
    /// the user from discovering that by trying.
    var offersAttachments: Bool = true
    var onPastRecordings: () -> Void
    var onPastMessages: () -> Void
    var onAddPhoto: () -> Void
    var onAddFile: () -> Void
    var onTemporaryNote: () -> Void
    var onSecretGrant: () -> Void
    var onRestorePreviousText: () -> Void
    /// Cancel, Undo send, Send now and Move to background — each a session action, drawn in the
    /// order ``ComposerSessionAction/entries(hasSession:offersProcessActions:canGrantSecretAccess:)``
    /// gives them.
    var onCancel: () -> Void
    var onUndoSend: () -> Void = {}
    var onSendNow: () -> Void = {}
    var onMoveToBackground: () -> Void = {}
    /// False for a pod-resident (ultra-fast) session, which has no process to hold a queue or run
    /// a command.
    var offersProcessActions: Bool = true
    var onStartCallAfterSend: () -> Void = {}

    private var computerLabel: String {
        if isOnTheCall { return "Back to the call in this session" }
        return isCallLive ? "Back to the call" : "Talk to Computer"
    }

    var body: some View {
        Menu {
            if offersStartCallAfterSend {
                Button {
                    onStartCallAfterSend()
                } label: {
                    Label("Dictate Hands-Free", systemImage: "mic.fill")
                }
                .accessibilityIdentifier("composer-menu-start-call-after-send")
                Divider()
            }
            if offersComputer {
                Button {
                    onComputer()
                } label: {
                    Label(computerLabel, systemImage: isCallLive ? "waveform" : "waveform.circle")
                }
                .accessibilityIdentifier("composer-menu-computer")
                if !isCallLive {
                    Button {
                        onCallThisSession()
                    } label: {
                        Label("Call this session", systemImage: "phone.arrow.up.right")
                    }
                    .accessibilityIdentifier("composer-menu-call-this-session")
                }
                Divider()
            }
            Button {
                onPastRecordings()
            } label: {
                Label("Past Recordings", systemImage: "waveform")
            }
            Button {
                onPastMessages()
            } label: {
                Label("Past Messages", systemImage: "text.bubble")
            }
            if offersAttachments {
                Button {
                    onAddPhoto()
                } label: {
                    Label("Add Photo", systemImage: "photo.on.rectangle")
                }
                Button {
                    onAddFile()
                } label: {
                    Label("Add File", systemImage: "paperclip")
                }
            }
            Button {
                onTemporaryNote()
            } label: {
                Label("Temporary Note", systemImage: "note.text")
            }
            ForEach(
                ComposerSessionAction.entries(
                    hasSession: hasSession, offersProcessActions: offersProcessActions,
                    canGrantSecretAccess: canGrantSecretAccess),
                id: \.self
            ) { action in
                Button(role: Self.role(for: action)) {
                    perform(action)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
                .accessibilityIdentifier("composer-menu-\(action.rawValue)")
            }
            if let pregrantArmed {
                Button {
                    onTogglePregrant()
                } label: {
                    if pregrantArmed {
                        Label("Cancel Secret Grant", systemImage: "xmark.circle")
                    } else {
                        Label("Grant Secrets on Start", systemImage: "key")
                    }
                }
                .accessibilityIdentifier("composer-menu-pregrant")
            }
            if canRestorePreviousText {
                Button {
                    onRestorePreviousText()
                } label: {
                    Label("Restore earlier version", systemImage: "arrow.uturn.backward")
                }
                .accessibilityIdentifier("composer-menu-restore-previous-text")
            }
        } label: {
            // Unfilled — a solid white disc here was the single brightest object on the whole
            // transcript, louder than any message in it. An attachment menu is a secondary
            // affordance beside the conversation; it does not need to outshine it, matching the
            // web's own plain, low-key icon button for the same control.
            Image(systemName: "plus.circle")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(PaiPalette.Semantic.textSecondary)
        }
        // A Menu opened from a bar at the bottom of the screen may list its items bottom-up;
        // the fixed order is the one declared above, so Cancel stays first whatever the edge.
        .menuOrder(.fixed)
        .accessibilityIdentifier("composer-action-menu")
        .accessibilityLabel("More options")
    }

    private static func role(for action: ComposerSessionAction) -> ButtonRole? {
        action == .cancel ? .destructive : nil
    }

    private func perform(_ action: ComposerSessionAction) {
        switch action {
        case .cancel: onCancel()
        case .undoSend: onUndoSend()
        case .sendNow: onSendNow()
        case .moveToBackground: onMoveToBackground()
        case .grantSecretAccess: onSecretGrant()
        }
    }
}
