import PAIKit
import SwiftUI

/// The plus button's menu — a native `Menu`, matching the "must feel native" constraint directly
/// rather than porting the web's absolutely-positioned popover. Item order mirrors the web's plus
/// menu (`MessageInput.tsx`). `Cancel` needs only a session to exist; `Grant Secret Access` needs
/// the server to say this particular one is grantable — the two are gated separately rather than
/// both riding `hasSession`.
struct ComposerActionMenu: View {
    var hasSession: Bool
    /// `nil` when the menu should offer nothing about call mode: a call already running that
    /// this screen has nothing to say about, or a new session already marked as one.
    var callMenuState: ComposerCallMenuState? = nil
    /// The other session's own title, for `.runningElsewhere`'s label — `nil` falls back to a
    /// generic phrase rather than an empty one.
    var otherCallSessionName: String? = nil
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
    /// Unreachable while `callMenuState` is `nil` — the item that would call it is never in the
    /// menu — so `CreateSessionView`'s own composer, which has no session yet, needs no override.
    var onStartOrReturnToCall: () -> Void = {}
    var onEndCall: () -> Void = {}
    /// Only ever called for `.startAfterSend` — the new-session screen's own case.
    var onStartCallAfterSend: () -> Void = {}

    var body: some View {
        Menu {
            if let callMenuState {
                callModeItems(state: callMenuState)
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

    @ViewBuilder
    private func callModeItems(state: ComposerCallMenuState) -> some View {
        switch state {
        case .start:
            Button {
                onStartOrReturnToCall()
            } label: {
                Label("Start Call Mode", systemImage: "phone.fill")
            }
            .accessibilityIdentifier("composer-menu-start-call")
        case .returnToCall:
            Button {
                onStartOrReturnToCall()
            } label: {
                Label("Return to Call", systemImage: "phone.fill")
            }
            .accessibilityIdentifier("composer-menu-return-to-call")
            Button(role: .destructive) {
                onEndCall()
            } label: {
                Label("End Call", systemImage: "phone.down.fill")
            }
            .accessibilityIdentifier("composer-menu-end-call")
        case .startAfterSend:
            Button {
                onStartCallAfterSend()
            } label: {
                Label("Send as Call", systemImage: "phone.fill")
            }
            .accessibilityIdentifier("composer-menu-start-call-after-send")
        case .runningElsewhere:
            Button {
                onStartOrReturnToCall()
            } label: {
                Label(
                    "Switch Call Here" + (otherCallSessionName.map { " (from \($0))" } ?? ""),
                    systemImage: "arrow.triangle.swap")
            }
            .accessibilityIdentifier("composer-menu-switch-call")
        }
    }
}
