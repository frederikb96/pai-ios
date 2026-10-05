import PAIKit
import SwiftUI

/// The model choices as checkmark rows — the same list the worker gets (Default, Haiku, Sonnet,
/// Opus, Fable; Default is `nil`, the plan's own model), shared by the scheduled-task editor's
/// supervisor section and the session menu's attach form.
struct ModelRows: View {
    let selected: String?
    let onSelect: (String?) -> Void

    var body: some View {
        ForEach(CreateSessionStore.modelOptions, id: \.label) { option in
            ChoiceRow(label: option.label, isSelected: selected == option.id) { onSelect(option.id) }
                .accessibilityIdentifier("model-row-\(option.id ?? "default")")
        }
    }
}

/// A thinking-level choice, one row per level the model accepts plus the "no level" row, which
/// means the plan's own effort for a worker and thinking switched off for a supervisor
/// (`nullLabel`). Offered only once there is a level to pick, so callers render it under
/// `if !levels.isEmpty`.
struct ThinkingRows: View {
    let levels: [String]
    let selected: String?
    let nullLabel: String
    let onSelect: (String?) -> Void

    var body: some View {
        ChoiceRow(label: nullLabel, isSelected: selected == nil) { onSelect(nil) }
        ForEach(levels, id: \.self) { level in
            ChoiceRow(
                label: CreateSessionStore.effortLevelLabels[level] ?? level, isSelected: selected == level
            ) { onSelect(level) }
        }
    }
}

private struct ChoiceRow: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label).foregroundStyle(PaiPalette.Semantic.textPrimary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(PaiPalette.primary500)
                }
            }
        }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
