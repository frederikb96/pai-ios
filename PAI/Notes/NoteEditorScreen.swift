import PAIKit
import SwiftUI

/// One note, open for editing.
struct NoteEditorScreen: View {
    let noteID: String

    @Environment(NotesStore.self) private var notes
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let body = notes.body(for: noteID) {
                NoteEditorSurface(
                    text: body,
                    onChange: { notes.edit(id: noteID, body: $0) }
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .paiScreenBackground()
        .navigationTitle(notes.detail(for: noteID)?.name ?? notes.summary(for: noteID)?.name ?? "Note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NoteSaveStateBadge(state: notes.saveState(for: noteID))
            }
        }
        .task { await notes.loadNote(id: noteID) }
        // A pending edit must not wait on the debounce when the app is leaving the foreground:
        // iOS can suspend before it fires, and the edit would be gone with no sign it existed.
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            Task { await notes.flush(id: noteID) }
        }
        .onDisappear {
            Task { await notes.flush(id: noteID) }
        }
    }
}

/// What the editor shows about whether the note is safe.
///
/// Deliberately quiet for the states that need no attention — a badge that is always visible
/// trains the eye to ignore it, and the two states that matter are the two nobody must miss.
private struct NoteSaveStateBadge: View {
    let state: NoteSaveState

    var body: some View {
        switch state {
        case .clean:
            EmptyView()
        case .dirty:
            Image(systemName: "pencil")
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .accessibilityLabel("Unsaved changes")
        case .saving:
            ProgressView()
                .accessibilityLabel("Saving")
        case .conflict:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(PaiPalette.Semantic.warningText)
                .accessibilityLabel("This note changed elsewhere")
        case .failed(let message):
            Image(systemName: "exclamationmark.icloud.fill")
                .foregroundStyle(PaiPalette.Semantic.errorText)
                .accessibilityLabel("Not saved: \(message)")
        }
    }
}
