import PAIKit
import SwiftUI

/// The supervisor's model choices as checkmark rows — shared by the scheduled-task editor and the
/// session menu's attach form, which configure the same thing. Rows rather than a pill strip: the
/// default model's label ("Opus (supervisor default)") does not fit five-across on a phone.
struct SupervisorModelRows: View {
    let storedModel: String?
    let defaultModel: String?
    let onSelect: (String?) -> Void

    var body: some View {
        let shown = SupervisorModelChoice.shownModel(stored: storedModel, defaultModel: defaultModel)
        ForEach(SupervisorModelChoice.options(defaultModel: defaultModel), id: \.label) { option in
            ChoiceRow(label: option.label, isSelected: shown == option.id) { onSelect(option.id) }
                .accessibilityIdentifier("supervisor-model-\(option.id ?? "supervisor-default")")
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
