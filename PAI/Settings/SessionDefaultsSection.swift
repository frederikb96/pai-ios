import PAIKit
import SwiftUI

/// What ultra-fast and fast sessions run on when a session names nothing: one backend setting
/// every client reads, saved on each pick.
struct SessionDefaultsSection: View {
    let store: SessionDefaultsStore

    var body: some View {
        Group {
            if let defaults = store.defaults {
                ultrafastGroup(defaults.ultrafast)
                fastGroup(defaults.fast)
            } else {
                Section("Session defaults") {
                    if let error = store.errorMessage {
                        errorText(error)
                    } else {
                        ProgressView()
                    }
                }
            }
        }
        .task { await store.load() }
    }

    private func ultrafastGroup(_ ultrafast: SessionDefaults.UltraFast) -> some View {
        Section {
            picker(
                "Model", identifier: "ultrafast-default-model", selection: ultrafast.model,
                options: store.ultrafastModelIds, label: UltraFastModelInfo.label(for:)
            ) { id in
                SessionDefaultsUpdate(ultrafastModel: id)
            }
            picker(
                "Thinking", identifier: "ultrafast-default-thinking", selection: ultrafast.reasoningEffort,
                options: store.ultrafastEfforts, label: thinkingLabel
            ) { level in
                SessionDefaultsUpdate(ultrafastReasoningEffort: level)
            }
            if let error = store.errorMessage { errorText(error) }
        } header: {
            Text("Ultra-fast sessions")
        } footer: {
            Text("A new session can pick another model for itself.")
        }
    }

    private func fastGroup(_ fast: SessionDefaults.Fast) -> some View {
        Section("Fast sessions") {
            picker(
                "Model", identifier: "fast-default-model", selection: fast.model,
                options: store.fastModels, label: SessionModelSwitch.aliasLabel
            ) { alias in
                SessionDefaultsUpdate(fastModel: alias)
            }
            picker(
                "Thinking", identifier: "fast-default-thinking", selection: fast.thinking,
                options: store.fastLevels, label: thinkingLabel
            ) { level in
                SessionDefaultsUpdate(fastThinking: level)
            }
        }
    }

    private func picker(
        _ title: String, identifier: String, selection: String, options: [String],
        label: @escaping (String) -> String, update: @escaping (String) -> SessionDefaultsUpdate
    ) -> some View {
        Picker(
            title,
            selection: Binding(
                get: { selection },
                set: { value in Task { await store.save(update(value)) } }
            )
        ) {
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(option)
            }
        }
        .disabled(store.isSaving)
        .accessibilityIdentifier(identifier)
    }

    private func thinkingLabel(_ level: String) -> String {
        CreateSessionStore.effortLevelLabels[level] ?? level
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(PaiTypography.caption.font)
            .foregroundStyle(PaiPalette.Semantic.errorText)
    }
}
