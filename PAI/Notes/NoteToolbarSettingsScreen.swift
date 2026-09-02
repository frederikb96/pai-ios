import PAIKit
import SwiftUI

/// Enables, disables and reorders the note editor's formatting bar (spec row 6.5), reached from
/// the note index's "…" menu, beside Containers and Sort by.
///
/// A sheet with its own `NavigationStack` rather than a pushed route, the same shape
/// `NoteTagFilterSheet` already uses — this screen has no route of its own in `Route.swift`.
/// Two sections rather than one flat reorderable list: the persisted layout is only ever the
/// *enabled* actions in order (`SettingsStore.noteToolbarLayout`), so "move a disabled action"
/// has no defined meaning — dragging only ever reorders within "On the bar", and a tap moves an
/// action between the two sections.
struct NoteToolbarSettingsScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    private var disabledActions: [NoteToolbarActionId] {
        let enabled = Set(settings.noteToolbarLayout)
        return NoteToolbarLayout.allActionsInDefaultOrder.filter { !enabled.contains($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(settings.noteToolbarLayout, id: \.self) { id in
                        row(for: id, isEnabled: true)
                            .listRowBackground(PaiPalette.Notes.panelBackground)
                    }
                    .onMove { offsets, destination in
                        var layout = settings.noteToolbarLayout
                        layout.move(fromOffsets: offsets, toOffset: destination)
                        settings.setNoteToolbarLayout(layout)
                    }
                } header: {
                    Text("On the bar")
                } footer: {
                    Text("Drag to reorder. Changes apply to the bar immediately.")
                }

                if !disabledActions.isEmpty {
                    Section("Available") {
                        ForEach(disabledActions, id: \.self) { id in
                            row(for: id, isEnabled: false)
                                .listRowBackground(PaiPalette.Notes.panelBackground)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .paiNotesListBackground()
            // Drag handles shown at once rather than behind a separate Edit tap — this screen's
            // only purpose is reordering, the same reasoning `EditButton` exists to serve
            // elsewhere but unnecessary here since there is nothing else on the screen to protect
            // from an accidental drag.
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Formatting bar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reset") {
                        settings.setNoteToolbarLayout(NoteToolbarLayout.defaultLayout)
                    }
                    .disabled(settings.noteToolbarLayout == NoteToolbarLayout.defaultLayout)
                }
            }
        }
    }

    private func row(for id: NoteToolbarActionId, isEnabled: Bool) -> some View {
        Toggle(
            isOn: Binding(
                get: { isEnabled },
                set: { toggle(id, enable: $0) }
            )
        ) {
            Label(id.label, systemImage: id.symbolName)
                .foregroundStyle(PaiPalette.Semantic.textPrimary)
        }
    }

    private func toggle(_ id: NoteToolbarActionId, enable: Bool) {
        var layout = settings.noteToolbarLayout
        if enable {
            guard !layout.contains(id) else { return }
            layout.append(id)
        } else {
            layout.removeAll { $0 == id }
        }
        settings.setNoteToolbarLayout(layout)
    }
}
