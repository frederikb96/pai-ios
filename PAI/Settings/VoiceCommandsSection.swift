import PAIKit
import SwiftUI

/// The offline command channel's settings: what each spoken command is configured to (a default
/// plus every built-in variant, `CommandPhraseSet`), and the one-time, at-home download the
/// on-device model needs before it works offline (`OnDeviceCommandListener.installAssets`) — a
/// call never triggers that download itself.
struct VoiceCommandsSection: View {
    let commands: CommandPhrasesStore
    let settings: SettingsStore

    @State private var assetsInstalled: Bool?
    @State private var isInstalling = false
    @State private var installError: String?

    var body: some View {
        Section {
            ForEach(CommandKind.allCases, id: \.self) { kind in
                LabeledContent(label(for: kind)) {
                    TextField(CommandPhraseSet.defaults.phrases[kind] ?? "", text: phraseBinding(for: kind))
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("voice-command-\(kind.rawValue)")
                }
            }
            Button("Reset to Defaults") { commands.resetToDefaults() }
        } header: {
            Text("Voice Commands")
        } footer: {
            Text(
                "A pause before the phrase, and nothing spoken after it, is what tells a command apart from just mentioning it."
            )
        }

        Section {
            assetStatusContent
        } header: {
            Text("Offline Model")
        } footer: {
            Text("Downloads once, at home — a call never starts this download itself.")
        }
        .task { await refreshAssetStatus() }
    }

    @ViewBuilder
    private var assetStatusContent: some View {
        if isInstalling {
            HStack {
                ProgressView()
                Text("Downloading…")
            }
        } else if assetsInstalled == true {
            Text("Downloaded")
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .accessibilityIdentifier("voice-commands-asset-status")
        } else {
            Button("Download Offline Voice Commands") {
                Task { await install() }
            }
            .accessibilityIdentifier("voice-commands-asset-status")
        }
        if let installError {
            Text(installError)
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.errorText)
        }
    }

    private func label(for kind: CommandKind) -> String {
        switch kind {
        case .start: return "Start"
        case .stop: return "Stop"
        case .skip: return "Skip"
        case .mute: return "Mute"
        case .unmute: return "Unmute"
        case .end: return "End Call"
        }
    }

    private func phraseBinding(for kind: CommandKind) -> Binding<String> {
        Binding(
            get: { commands.phraseSet.phrases[kind] ?? "" },
            set: { commands.setPhrase($0, for: kind) })
    }

    /// `.auto` maps to `en-US`, matching the STT language picker's own recommended default for
    /// an unset preference — this type does not invent a second convention for the same choice.
    private var locale: Locale {
        switch settings.sttLanguage {
        case .de: return Locale(identifier: "de-DE")
        case .en, .auto: return Locale(identifier: "en-US")
        }
    }

    private func refreshAssetStatus() async {
        assetsInstalled = await OnDeviceCommandListener.assetsInstalled(locale: locale)
    }

    private func install() async {
        isInstalling = true
        installError = nil
        defer { isInstalling = false }
        do {
            try await OnDeviceCommandListener.installAssets(locale: locale)
            assetsInstalled = await OnDeviceCommandListener.assetsInstalled(locale: locale)
        } catch {
            installError = "Could not download the offline model: \(error.localizedDescription)"
        }
    }
}
