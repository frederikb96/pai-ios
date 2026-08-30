import PAIKit
import SwiftUI

/// The plus button's menu — a native `Menu`, matching the "must feel native" constraint directly
/// rather than porting the web's absolutely-positioned popover. Item order and the
/// existing-session-only `Cancel` item mirror the web's plus menu exactly
/// (`MessageInput.tsx`: "nothing is running before the session exists").
struct ComposerActionMenu: View {
    var hasSession: Bool
    var onPastRecordings: () -> Void
    var onAddPhoto: () -> Void
    var onAddFile: () -> Void
    var onTemporaryNote: () -> Void
    var onCancel: () -> Void

    var body: some View {
        Menu {
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
            if hasSession {
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
