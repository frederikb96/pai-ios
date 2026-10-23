import PAIKit
import SwiftUI

/// The line the notes screens show while the server cannot be reached: what is on screen comes
/// from this phone, and "Sync now" sends whatever is waiting. Static, like every status line here.
struct NotesOfflineBanner: View {
    let text: String

    @Environment(NotesStore.self) private var notes
    @State private var isSyncing = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "icloud.slash")
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Sync now") {
                Task {
                    isSyncing = true
                    defer { isSyncing = false }
                    await notes.refresh()
                    await notes.resumeSync()
                }
            }
            .disabled(isSyncing)
            .accessibilityIdentifier("notes-sync-now")
        }
        .font(PaiTypography.caption.font)
        .foregroundStyle(PaiPalette.Semantic.warningText)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(PaiPalette.Semantic.warningBackground)
        .accessibilityIdentifier("notes-offline-banner")
    }
}

/// What a note shows when it was never kept on this phone and there is no connection to fetch it.
struct NoteUnavailableOfflineView: View {
    let noteID: String

    @Environment(NotesStore.self) private var notes

    var body: some View {
        ContentUnavailableView {
            Label("Not available offline", systemImage: "icloud.slash")
        } description: {
            Text(NoteOnlineOnly.noteUnavailable.message)
        } actions: {
            Button("Retry") { Task { await notes.loadNote(id: noteID) } }
        }
    }
}
