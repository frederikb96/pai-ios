import PAIKit
import SwiftUI

/// The note index.
struct NoteListScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(NotesStore.self) private var notes

    @State private var filterText = ""

    var body: some View {
        list
            .paiScreenBackground()
            .navigationTitle("Notes")
            .searchable(text: $filterText, prompt: "Filter notes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        environment.router.push(.noteContainers)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("Note containers")
                    .accessibilityIdentifier("open-note-containers")
                }
            }
            .task {
                guard notes.notes.isEmpty else { return }
                await notes.refresh()
            }
            .refreshable { await notes.refresh() }
    }

    @ViewBuilder
    private var list: some View {
        if let error = notes.loadError, notes.notes.isEmpty {
            ContentUnavailableView(
                "Notes unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if notes.notes.isEmpty && !notes.isLoading {
            ContentUnavailableView(
                "No notes", systemImage: "note.text",
                description: Text("Notes synced from a container appear here."))
        } else {
            List(visibleNotes) { note in
                Button {
                    environment.router.push(.note(id: note.id))
                } label: {
                    NoteRow(note: note)
                }
                .buttonStyle(.plain)
                .listRowBackground(PaiPalette.Semantic.panelBackground)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var visibleNotes: [NoteSummary] {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return notes.notes }
        return notes.notes.filter {
            $0.name.lowercased().contains(needle) || ($0.summary?.lowercased().contains(needle) ?? false)
        }
    }
}

private struct NoteRow: View {
    let note: NoteSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.name)
                    .font(PaiTypography.bodyEmphasized.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                if let summary = note.summary, !summary.isEmpty {
                    Text(summary)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if note.favourite {
                Image(systemName: "star.fill")
                    .foregroundStyle(PaiPalette.Semantic.accentText)
            }
        }
        .padding(.vertical, 4)
        // A row laid out with a `Spacer()` is hit-tested against what it draws, so the empty
        // width beside the text would ignore a tap without this.
        .contentShape(Rectangle())
    }
}
