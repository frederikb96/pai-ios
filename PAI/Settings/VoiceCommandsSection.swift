import PAIKit
import SwiftUI

/// The offline command channel's settings: which commands run through the wake-word engine at
/// all, versus falling back to recognition from the dictated text while recording, and each
/// loaded command's own bundled-model status. The phrases themselves have no field here — they
/// are fixed, baked into trained classifiers, never typed.
struct VoiceCommandsSection: View {
    let wakeWord: WakeWordSettingsStore

    var body: some View {
        Section {
            ForEach(CommandKind.allCases, id: \.self) { kind in
                Toggle(isOn: offlineBinding(for: kind)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label(for: kind))
                        if wakeWord.config.offlineCommands.contains(kind) {
                            Text(modelStatusText(for: kind))
                                .font(PaiTypography.caption.font)
                                .foregroundStyle(
                                    modelIsBundled(kind)
                                        ? PaiPalette.Semantic.textMuted : PaiPalette.Semantic.errorText)
                        }
                    }
                }
                .accessibilityIdentifier("voice-command-\(kind.rawValue)-offline")
            }
        } header: {
            Text("Voice Commands")
        } footer: {
            Text(
                "On: heard by the offline model, even with no connection. Off: recognized from the dictated text instead, only while recording."
            )
        }

        Section {
            Button("Use Full Chart") { wakeWord.useFullChart() }
                .accessibilityIdentifier("voice-commands-use-full-chart")
            Button("Use Start-Only Fallback") { wakeWord.useStartOnlyFallback() }
                .accessibilityIdentifier("voice-commands-use-start-only-fallback")
        } footer: {
            Text(
                "The start-only fallback listens offline for \"Kai start\" alone; every other command is recognized from the dictated text."
            )
        }
    }

    private func offlineBinding(for kind: CommandKind) -> Binding<Bool> {
        Binding(
            get: { wakeWord.config.offlineCommands.contains(kind) },
            set: { isOn in
                var commands = wakeWord.config.offlineCommands
                if isOn { commands.insert(kind) } else { commands.remove(kind) }
                wakeWord.setOfflineCommands(commands)
            })
    }

    private func modelIsBundled(_ kind: CommandKind) -> Bool {
        WakeWordCommandListener.modelURL(for: kind) != nil
    }

    private func modelStatusText(for kind: CommandKind) -> String {
        modelIsBundled(kind) ? "Model ready" : "Model not bundled yet — this command won't fire offline"
    }

    private func label(for kind: CommandKind) -> String {
        switch kind {
        case .start: return "Start"
        case .stop: return "Stop"
        case .send: return "Send"
        case .skip: return "Skip"
        case .end: return "End Call"
        case .interrupt: return "Interrupt"
        }
    }
}
