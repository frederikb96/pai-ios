import PAIKit
import SwiftUI

/// How much of the notes vault this phone keeps for offline use, what it holds now, and the way
/// to empty it. Edits not yet synced are a separate store; clearing never touches them.
struct NotesCacheSection: View {
    let settings: SettingsStore
    @Environment(AppEnvironment.self) private var environment

    @State private var status: NotesCacheStatus?
    @State private var confirmingClear = false

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
