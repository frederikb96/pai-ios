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
                Text(workingDir)
                    .font(PaiTypography.caption.font)
                    .textSelection(.enabled)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            .padding(14)
            .frame(maxWidth: 320, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
    }
}
