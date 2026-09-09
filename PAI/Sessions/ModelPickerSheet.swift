import PAIKit
import SwiftUI

/// The model + thinking picker — a modal over `CreateSessionView`, mirroring the web's own
/// `ModelPicker.tsx`: a list of models, then — once one is known — that model's own thinking
/// levels, read from `CreateSessionStore.sessionModels` (`GET /api/session-models`) rather than
/// a hand-mirrored copy of the vocabulary.
///
/// A model is always known here even before Freddy picks one: `createSession.resolvedModel`
/// already falls back to the fast sandbox's own default (`createSession.fastDefaultModel`/
/// `fastDefaultThinking`, read from `GET /api/session-models`) on a fast session, so the row
/// that default resolves to reads as selected without either flag ever being written until he
/// actually taps something.
struct ModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let createSession: CreateSessionStore
    let onSelectModel: (String?) -> Void
    let onSelectThinking: (String?) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Model") {
                    modelRow(id: nil, label: "Default")
                    ForEach(createSession.sessionModels) { model in
                        modelRow(id: model.id, label: CreateSessionStore.modelDisplayLabels[model.id] ?? model.id)
                    }
                }

                // Only once a model is known — "Default" thinking has no meaning without one,
                // and a model with no effort levels of its own offers none.
                if createSession.resolvedModel != nil, !createSession.effortLevelsForResolvedModel.isEmpty {
                    Section("Thinking") {
                        thinkingRow(id: nil, label: "Default")
                        ForEach(createSession.effortLevelsForResolvedModel, id: \.self) { level in
                            thinkingRow(id: level, label: CreateSessionStore.effortLevelLabels[level] ?? level)
                        }
                    }
                }

                if createSession.isFastSelected {
                    Section {
                        Text(fastDefaultCaption)
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.textMuted)
                    }
                }
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("model-picker-done")
                }
            }
        }
    }

    /// Built outside the view builder on purpose: the concatenation and its two
    /// dictionary lookups are more than the SwiftUI type-checker will accept inline,
    /// and it fails only on a real Xcode build of the app target.
    private var fastDefaultCaption: String {
        let model: String =
            CreateSessionStore.modelDisplayLabels[createSession.fastDefaultModel]
            ?? createSession.fastDefaultModel
        let thinking: String =
            CreateSessionStore.effortLevelLabels[createSession.fastDefaultThinking]
            ?? createSession.fastDefaultThinking
        return "Fast sessions run \(model) at \(thinking) thinking unless you choose otherwise here."
    }

    private func modelRow(id: String?, label: String) -> some View {
        let isSelected = createSession.resolvedModel == id
        return Button {
            onSelectModel(id)
        } label: {
            HStack {
                Text(label).foregroundStyle(PaiPalette.Semantic.textPrimary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(PaiPalette.primary500)
                }
            }
        }
        .accessibilityIdentifier("model-picker-model-\(id ?? "default")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func thinkingRow(id: String?, label: String) -> some View {
        let isSelected = createSession.resolvedThinking == id
        return Button {
            onSelectThinking(id)
        } label: {
            HStack {
                Text(label).foregroundStyle(PaiPalette.Semantic.textPrimary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(PaiPalette.primary500)
                }
            }
        }
        .accessibilityIdentifier("model-picker-thinking-\(id ?? "default")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
