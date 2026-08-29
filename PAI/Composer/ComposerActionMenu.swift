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
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(PaiPalette.Semantic.textSecondary)
        }
        .accessibilityIdentifier("composer-action-menu")
        .accessibilityLabel("More options")
    }
}
