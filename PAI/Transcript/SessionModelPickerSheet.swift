import PAIKit
import SwiftUI

/// The sheet the header's model badge opens: one tap on a model switches this session to it, from
/// its next reply on and again when it is resumed. Mirrors the web's `SessionModelPicker`.
struct SessionModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts
    let store: SessionModelSwitchStore
    let current: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.catalog.models) { model in
                        modelRow(id: model.id)
                    }
                } header: {
                    Text("Model")
                } footer: {
                    Text("Applies to this session only, from its next reply, and stays when it is resumed.")
                }

                if let message = store.errorMessage {
                    Section {
                        Text(message)
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.errorText)
                            .accessibilityIdentifier("session-model-picker-error")
                    }
                }
            }
            .navigationTitle("Model for this session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("session-model-picker-done")
                }
            }
        }
        .task { await store.load() }
    }

    private func modelRow(id: String) -> some View {
        let isSelected = current == id
        return Button {
            Task { await choose(id) }
        } label: {
            HStack {
                Text(SessionModelSwitch.aliasLabel(id)).foregroundStyle(PaiPalette.Semantic.textPrimary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(PaiPalette.primary500)
                }
            }
        }
        .disabled(store.isBusy)
        .accessibilityIdentifier("session-model-picker-\(id)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func choose(_ id: String) async {
        switch await store.choose(id, current: current) {
        case .unchanged, .switched:
            dismiss()
        case let .nextLaunch(message):
            dismiss()
            toasts.show(message)
        case .failed:
            break
        }
    }
}

/// The header's picker for an ultra-fast session: model and thinking, both for this session only,
/// from its next reply. It stays open after a pick, since the thinking levels depend on the model
/// just chosen. Mirrors the web's `UltraFastSessionModelPicker`.
struct UltraFastSessionModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: SessionModelSwitchStore
    let session: Session
    /// The picks of this sheet, shown before the session list catches up.
    @State private var pickedModel: String?
    @State private var pickedThinking: String?

    private var model: String? { pickedModel ?? session.ultrafastModel ?? store.ultrafastCatalog?.defaultModel }
    private var thinking: String? {
        if pickedThinking != nil || pickedModel != nil { return pickedThinking }
        return session.thinking ?? store.ultrafastCatalog?.defaultThinking
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.ultrafastCatalog?.models ?? []) { option in
                        row(
                            label: UltraFastModelInfo.label(for: option.id), isSelected: option.id == model,
                            identifier: "ultrafast-picker-model-\(option.id)"
                        ) {
                            guard option.id != model else { return }
                            Task {
                                if await store.chooseUltrafast(model: option.id, thinking: nil) {
                                    pickedModel = option.id
                                    pickedThinking = nil
                                }
                            }
                        }
                    }
                } header: {
                    Text("Model")
                } footer: {
                    Text("Applies to this session only, from its next reply, and stays when it is resumed.")
                }

                if let model, let levels = store.ultrafastCatalog?.levels(for: model), !levels.isEmpty {
                    Section("Thinking") {
                        ForEach(levels, id: \.self) { level in
                            row(
                                label: CreateSessionStore.effortLevelLabels[level] ?? level,
                                isSelected: level == thinking, identifier: "ultrafast-picker-thinking-\(level)"
                            ) {
                                Task {
                                    if await store.chooseUltrafast(model: model, thinking: level) {
                                        pickedModel = model
                                        pickedThinking = level
                                    }
                                }
                            }
                        }
                    }
                }

                if let message = store.errorMessage {
                    Section {
                        Text(message)
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.errorText)
                    }
                }
            }
            .navigationTitle("Model for this session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("ultrafast-picker-done")
                }
            }
        }
        .task { await store.load() }
    }

    private func row(
        label: String, isSelected: Bool, identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(label).foregroundStyle(PaiPalette.Semantic.textPrimary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(PaiPalette.primary500)
                }
            }
        }
        .disabled(store.isBusy)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The folder icon beside the usage badge: a tap names the folder and shows the full path
/// (selectable, to copy), the phone's stand-in for the web's hover.
struct WorkingFolderButton: View {
    let workingDir: String
    @State private var isShowingPath = false

    var body: some View {
        Button {
            isShowingPath = true
        } label: {
            Image(systemName: "folder")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Working folder \(WorkingFolder.name(of: workingDir))")
        .accessibilityIdentifier("working-folder-button")
        .popover(isPresented: $isShowingPath) {
            VStack(alignment: .leading, spacing: 4) {
                Text(WorkingFolder.name(of: workingDir))
                    .font(PaiTypography.bodyEmphasized.font)
                // A popover sizes itself from its content's ideal height, which for
                // a Text is one line: without this the path ends in an ellipsis
                // instead of wrapping.
                Text(workingDir)
                    .font(PaiTypography.caption.font)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            .padding(14)
            .frame(maxWidth: 320, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
    }
}
