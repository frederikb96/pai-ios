import PAIKit
import SwiftUI

/// One note, open for editing.
struct NoteEditorScreen: View {
    let noteID: String

    @Environment(AppEnvironment.self) private var environment
    @Environment(NotesStore.self) private var notes
    @Environment(\.scenePhase) private var scenePhase

    /// Edit and preview are exclusive modes, as they are on the web. Not a live preview — see
    /// `MarkdownSourceHighlighter` for why the editor styles the markup instead of replacing it.
    @State private var isPreviewing = false
    @State private var isShowingTools = false
    @State private var isShowingActions = false
    /// Where the tools panel last asked the editor to go. Tokenised so tapping the same heading
    /// twice is two requests rather than one that appears unchanged.
    @State private var jump: NoteJumpRequest?
    @State private var jumpToken = 0
    /// What the in-note search was looking for when it sent the reader somewhere — every
    /// occurrence of it stays painted in the preview until the next jump says otherwise.
    @State private var highlight: String?
    /// Outlives each presentation of the tools sheet, so reopening it lands where it was left.
    @State private var toolsState = NoteToolsPanelState()

    var body: some View {
        VStack(spacing: 0) {
            if case .conflict(let conflict) = notes.saveState(for: noteID) {
                NoteConflictBanner(noteID: noteID, conflict: conflict)
            }
            content
        }
        .paiNotesBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
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
        .sheet(isPresented: $isShowingTools) {
            NavigationStack {
                NoteToolsPanel(
                    noteId: noteID, onOpenNote: { openNote($0) },
                    onJumpTo: { jumpTo($0) },
                    state: toolsState)
            }
        }
        .sheet(isPresented: $isShowingActions) {
            NoteActionsSheet(
                noteId: noteID, onOpenNote: { openNote($0) },
                onJumpTo: { jumpTo($0) },
                // The note this sheet is about is the one already on screen, so offering to open
                // it would push a second copy of this very editor.
                showsOpenNote: false,
                onDeleted: { environment.router.dismissNote(id: noteID) })
        }
    }

    @ViewBuilder
    private var content: some View {
        if let body = notes.body(for: noteID) {
            if isPreviewing {
                NoteBodyView(
                    body: body, nameToId: buildNameToId(notes.notes),
                    containerId: notes.detail(for: noteID)?.containerId,
                    jump: jump, highlight: highlight)
            } else {
                NoteEditorSurface(
                    noteID: noteID, text: body, revision: notes.externalRevision(for: noteID), jump: jump,
                    highlight: highlight, onChange: { notes.edit(id: noteID, body: $0) })
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            NoteSaveStateBadge(state: notes.saveState(for: noteID))
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                // Flushed first, so what the preview renders is what was actually typed rather
                // than whatever the debounce last happened to save.
                Task { await notes.flush(id: noteID) }
                isPreviewing.toggle()
            } label: {
                Image(systemName: isPreviewing ? "pencil" : "eye")
            }
            .accessibilityLabel(isPreviewing ? "Edit" : "Preview")
            .accessibilityIdentifier("toggle-note-preview")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isShowingTools = true
            } label: {
                Image(systemName: "list.bullet.indent")
            }
            .accessibilityLabel("Outline, links and history")
            .accessibilityIdentifier("open-note-tools")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isShowingActions = true
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Note actions")
            .accessibilityIdentifier("open-note-actions")
        }
    }

    private var title: String {
        let name = notes.detail(for: noteID)?.name ?? notes.summary(for: noteID)?.name ?? ""
        return name.isEmpty ? "Untitled" : name
    }

    /// Go where the tools panel pointed — an outline heading, a search hit.
    ///
    /// Whichever mode is open answers it: the editor puts the caret there, the preview scrolls the
    /// rendered page there. Leaving preview to answer a jump would be the wrong reading of the ask
    /// — someone browsing a rendered note who taps a heading wants to be further down that page,
    /// not looking at its markup.
    private func jumpTo(_ target: NoteJumpTarget) {
        isShowingTools = false
        isShowingActions = false
        highlight = target.query
        jumpToken += 1
        jump = NoteJumpRequest(token: jumpToken, characterOffset: target.characterOffset)
    }

    /// Pushed rather than replaced: following a link from inside a note is navigation within the
    /// app, so Back has to return to the note it came from. A deep link is the opposite case and
    /// replaces the path — see `Router.openNote(id:)`.
    private func openNote(_ id: String) {
        isShowingTools = false
        isShowingActions = false
        environment.router.push(.note(id: id))
    }
}

/// The vault moved on under an edit, and the reader has to choose.
///
/// A banner rather than an alert, and it does not go away on its own: both versions exist and one
/// of them is about to be lost either way, so this is the one place in the app where an
/// interruption is the correct behaviour. Dismissing it silently — or letting the next autosave
/// pick a side — is how an edit disappears with nobody noticing.
private struct NoteConflictBanner: View {
    let noteID: String
    let conflict: NoteConflict

    @Environment(NotesStore.self) private var notes

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This note changed elsewhere", systemImage: "exclamationmark.triangle.fill")
                .font(PaiTypography.bodyEmphasized.font)
                .foregroundStyle(PaiPalette.Semantic.warningBannerText)
            Text("Your edits and the version on disk have both moved on. Keeping one discards the other.")
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.warningText)
            HStack(spacing: 12) {
                Button("Keep mine") {
                    Task { await notes.resolveConflict(id: noteID, keeping: .mine) }
                }
                .buttonStyle(.borderedProminent)
                Button("Use the version on disk") {
                    Task { await notes.resolveConflict(id: noteID, keeping: .theirs) }
                }
                .buttonStyle(.bordered)
            }
            .font(PaiTypography.caption.font)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(PaiPalette.Semantic.warningBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PaiPalette.Semantic.warningBorder).frame(height: 1)
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
