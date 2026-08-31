import PAIKit
import SwiftUI

/// Multi-select tag filter, as a sheet rather than a `Menu` — a `Menu` dismisses on every tap,
/// and Freddy wants to pick several tags without it closing between taps. `.searchable` finds one
/// by name in a large vocabulary; AND semantics across the selection are `NoteFilter.swift`'s
/// `noteHasAllTags`, unchanged by this view.
struct NoteTagFilterSheet: View {
    let options: [TagOption]
    @Binding var selected: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filteredOptions: [TagOption] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return options }
        return options.filter { noteMatchesQuery(name: $0.label, summary: nil, query: trimmed) }
    }

    var body: some View {
        NavigationStack {
            List(filteredOptions) { option in
                Button {
                    toggle(option.key)
                } label: {
                    HStack {
                        Text("\(option.label) (\(option.count))")
                            .foregroundStyle(PaiPalette.Semantic.textPrimary)
                        Spacer(minLength: 0)
                        if selected.contains(option.key) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(PaiPalette.primary500)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(PaiPalette.Semantic.panelBackground)
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Find a tag")
            .paiScreenBackground()
            .navigationTitle(selected.isEmpty ? "Tags" : "Tags (\(selected.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !selected.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear") { selected = [] }
                    }
                }
            }
        }
    }

    private func toggle(_ key: String) {
        if selected.contains(key) {
            selected.removeAll { $0 == key }
        } else {
            selected.append(key)
        }
    }
}
