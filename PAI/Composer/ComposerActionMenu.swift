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
    var onPastRecordings: () -> Void
    var onAddPhoto: () -> Void
    var onAddFile: () -> Void
    var onTemporaryNote: () -> Void
    var onSecretGrant: () -> Void
    var onCancel: () -> Void
    var onStartCallAfterSend: () -> Void = {}

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
            Button {
                onPastRecordings()
            } label: {
                Label("Past Recordings", systemImage: "waveform")
            }
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
            Button {
                onTemporaryNote()
            } label: {
                Label("Temporary Note", systemImage: "note.text")
            }
            if canGrantSecretAccess {
                Button {
                    onSecretGrant()
                } label: {
                    Label("Grant Secret Access", systemImage: "key")
                }
            }
            if hasSession {
                // Needs a real session id to cancel — unlike the other four entries, there is
                // nothing sensible for this one to do before a session exists.
                Button(role: .destructive) {
                    onCancel()
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
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
        .accessibilityIdentifier("composer-action-menu")
        .accessibilityLabel("More options")
    }
}
