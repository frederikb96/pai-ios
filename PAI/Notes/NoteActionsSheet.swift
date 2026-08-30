import PAIKit
import SwiftUI

/// Every action the web's note row menu, editor trash icon and right panel offer, in one sheet —
/// reached from a row's swipe action or context menu. Mirrors `SessionActionsSheet`'s own shape:
/// a `NavigationStack` inside a sheet, push-based rather than a hand-rolled back button.
struct NoteActionsSheet: View {
    let noteId: String
    /// Where "Open note" and a resolved link inside the tools panel should land — pushed onto
    /// the app's own navigation stack, which needs this sheet dismissed first or the note would
    /// open underneath it.
    let onOpenNote: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(NotesStore.self) private var notes
    @Environment(ToastCenter.self) private var toasts

    @State private var path: [NoteActionsRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            RootNoteActionsList(
                noteId: noteId, notes: notes, path: $path,
                onOpenNote: {
                    dismiss()
                    onOpenNote(noteId)
                },
                onDelete: {
                    Task {
                        guard await notes.requestDelete(id: noteId) else {
                            toasts.show(notes.loadError ?? "Could not delete the note", kind: .error)
                            return
                        }
                        dismiss()
                        toasts.show(
                            "Note deleted",
                            action: .init(label: "Undo") { [notes] in Task { await notes.undelete(id: noteId) } },
                            lifetimeNanos: 15_000_000_000
                        )
                    }
                }
            )
            .navigationDestination(for: NoteActionsRoute.self) { route in
                destination(for: route)
            }
            .navigationTitle(
                notes.summary(for: noteId)?.name.isEmpty == false ? notes.summary(for: noteId)!.name : "Untitled"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func destination(for route: NoteActionsRoute) -> some View {
        switch route {
        case .rename:
            RenameNoteView(noteId: noteId, notes: notes, toasts: toasts, onDone: { dismiss() })
        case .deleteConfirm:
            NoteDeleteConfirmView(
                noteId: noteId, notes: notes, onOpenNote: onOpenNote,
                onConfirm: {
                    Task {
                        guard await notes.requestDelete(id: noteId) else {
                            toasts.show(notes.loadError ?? "Could not delete the note", kind: .error)
                            return
                        }
                        dismiss()
                        toasts.show(
                            "Note deleted",
                            action: .init(label: "Undo") { [notes] in Task { await notes.undelete(id: noteId) } },
                            lifetimeNanos: 15_000_000_000
                        )
                    }
                })
        case .tools:
            NoteToolsPanel(
                noteId: noteId,
                onOpenNote: { id in
                    dismiss()
                    onOpenNote(id)
                })
        }
    }
}

private enum NoteActionsRoute: Hashable {
    case rename, deleteConfirm, tools
}

// MARK: - Root list

private struct RootNoteActionsList: View {
    let noteId: String
    let notes: NotesStore
    @Binding var path: [NoteActionsRoute]
    let onOpenNote: () -> Void
    let onDelete: () -> Void

    var body: some View {
        List {
            if let note = notes.summary(for: noteId) {
                Button {
                    onOpenNote()
                } label: {
                    Label("Open note", systemImage: "note.text")
                }

                Button {
                    path.append(.rename)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Button {
                    Task { await notes.setFavourite(id: noteId, favourite: !note.favourite) }
                } label: {
                    Label(
                        note.favourite ? "Remove from favourites" : "Add to favourites",
                        systemImage: note.favourite ? "star.fill" : "star")
                }

                Button {
                    path.append(.tools)
                } label: {
                    Label("Outline, links & history", systemImage: "sidebar.right")
                }

                Button(role: .destructive) {
                    path.append(.deleteConfirm)
                } label: {
                    Label("Delete note", systemImage: "trash")
                }
            } else {
                ProgressView()
            }
        }
        .accessibilityIdentifier("note-actions-list")
    }
}

// MARK: - Rename

private struct RenameNoteView: View {
    let noteId: String
    let notes: NotesStore
    let toasts: ToastCenter
    let onDone: () -> Void

    @State private var text: String
    @State private var isSaving = false

    init(noteId: String, notes: NotesStore, toasts: ToastCenter, onDone: @escaping () -> Void) {
        self.noteId = noteId
        self.notes = notes
        self.toasts = toasts
        self.onDone = onDone
        _text = State(initialValue: notes.summary(for: noteId)?.name ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("Note name", text: $text)
                    .accessibilityIdentifier("note-rename-field")
            }
        }
        .navigationTitle("Rename note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        if await notes.rename(id: noteId, name: text) {
            onDone()
        } else {
            toasts.show(notes.loadError ?? "Rename failed", kind: .error)
        }
    }
}

// MARK: - Delete confirmation

/// The delete confirmation, with what links here — matching the web's `DeleteNoteConfirm`: a
/// backlink surfaced HERE is a note that will read as broken once this one is gone, so it is
/// worth seeing before confirming rather than after.
private struct NoteDeleteConfirmView: View {
    let noteId: String
    let notes: NotesStore
    let onOpenNote: (String) -> Void
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true

    var body: some View {
        List {
            Section {
                Label {
                    Text(
                        "\"\(notes.summary(for: noteId)?.name.isEmpty == false ? notes.summary(for: noteId)!.name : "Untitled")\" will be removed from disk. You get a moment to undo it afterwards."
                    )
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                }
            }

            if let error = notes.linkGraphErrors[noteId] {
                Section { Text(error).foregroundStyle(PaiPalette.Semantic.errorText) }
            } else if let graph = notes.linkGraphs[noteId] {
                if graph.extractionSkipped {
                    Section {
                        Text("Some notes are too large to scan for links — there may be more backlinks than shown.")
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.amber500)
                    }
                }
                if graph.backlinks.isEmpty {
                    Section { Text("Nothing links to this note.").foregroundStyle(PaiPalette.Semantic.textMuted) }
                } else {
                    Section("\(graph.backlinks.count) \(graph.backlinks.count == 1 ? "note links" : "notes link") here")
                    {
                        ForEach(graph.backlinks) { backlink in
                            Button {
                                onOpenNote(backlink.noteId)
                            } label: {
                                HStack {
                                    Text(backlink.noteName.isEmpty ? "Untitled" : backlink.noteName)
                                        .foregroundStyle(PaiPalette.Semantic.textPrimary)
                                    Spacer()
                                    Text("\(backlink.count) \(backlink.count == 1 ? "link" : "links")")
                                        .font(PaiTypography.caption.font)
                                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                                }
                            }
                        }
                    }
                }
            } else if isLoading {
                Section { ProgressView() }
            }
        }
        .navigationTitle("Delete note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Delete", role: .destructive, action: onConfirm)
            }
        }
        .task {
            await notes.loadLinkGraph(id: noteId)
            isLoading = false
        }
    }
}
