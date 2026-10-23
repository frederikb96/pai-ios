import PAIKit
import SwiftUI

/// How much of the notes vault this phone keeps for offline use, what it holds now, and the way
/// to empty it. Edits not yet synced are a separate store; clearing never touches them.
///
/// Below it, when there is any, the text this phone holds that cannot sync by itself
/// (`NotesStore.keptTexts`): an edit to a note deleted elsewhere is no longer on the list, so this
/// is the one place it can still be reached.
struct NotesCacheSection: View {
    let settings: SettingsStore
    @Environment(AppEnvironment.self) private var environment

    @State private var status: NotesCacheStatus?
    @State private var confirmingClear = false
    @State private var discarding: NoteKeptText?

    private var notes: NotesStore? { environment.connection?.notes }

    var body: some View {
        Section {
            Picker("Keep up to", selection: budgetBinding) {
                ForEach(NotesCacheBudget.choices, id: \.self) { bytes in
                    Text(Self.size(bytes)).tag(bytes)
                }
            }
            .accessibilityIdentifier("notes-cache-budget")
            if let status {
                LabeledContent("Using", value: usage(status))
                    .accessibilityIdentifier("notes-cache-usage")
            }
            Button("Clear cached notes and files", role: .destructive) { confirmingClear = true }
                .accessibilityIdentifier("notes-cache-clear")
                .confirmationDialog(
                    "Clear cached notes and files?", isPresented: $confirmingClear, titleVisibility: .visible
                ) {
                    Button("Clear", role: .destructive) {
                        Task {
                            await notes?.clearCache()
                            status = await notes?.cacheStatus()
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Notes and files are fetched again when you open them. Edits not yet synced are kept.")
                }
        } header: {
            Text("Notes offline")
        } footer: {
            Text(
                "Notes you open, your favourites and files you view are kept on this phone so they open without a connection. Files are dropped oldest first to stay within this size; edits not yet synced are never dropped."
            )
        }
        .task { status = await notes?.cacheStatus() }
        if let notes, !notes.keptTexts.isEmpty {
            keptTexts(notes)
        }
    }

    private func keptTexts(_ notes: NotesStore) -> some View {
        Section {
            ForEach(notes.keptTexts) { kept in
                VStack(alignment: .leading, spacing: 6) {
                    Text(kept.title).foregroundStyle(PaiPalette.Semantic.textPrimary)
                    Text(kept.reason)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                    Text(kept.text)
                        .font(PaiTypography.caption.font)
                        .lineLimit(4)
                    HStack {
                        Button("Copy") { UIPasteboard.general.string = kept.text }
                            .buttonStyle(.bordered)
                        Button("Discard", role: .destructive) { discarding = kept }
                            .buttonStyle(.bordered)
                    }
                }
                .accessibilityIdentifier("notes-kept-text")
            }
        } header: {
            Text("Not saved")
        } footer: {
            Text(
                "Edits the server would not take, or that this version of the app cannot read. They are not sent again by themselves: copy the text somewhere, then discard it."
            )
        }
        .confirmationDialog(
            "Discard this text?", isPresented: discardingBinding, titleVisibility: .visible, presenting: discarding
        ) { kept in
            Button("Discard", role: .destructive) { notes.discardKeptText(kept) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It is removed from this phone.")
        }
    }

    private var discardingBinding: Binding<Bool> {
        Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } })
    }

    private var budgetBinding: Binding<Int> {
        Binding(
            get: { settings.notesCacheBudgetBytes },
            set: { bytes in
                settings.setNotesCacheBudget(bytes)
                notes?.setCacheBudget(bytes)
            })
    }

    private func usage(_ status: NotesCacheStatus) -> String {
        let notesCount = status.cachedBodyCount == 1 ? "1 note" : "\(status.cachedBodyCount) notes"
        let files = status.cachedAttachmentCount == 1 ? "1 file" : "\(status.cachedAttachmentCount) files"
        return "\(Self.size(status.cacheBytes)) · \(notesCount) · \(files)"
    }

    private static func size(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file))
    }
}
