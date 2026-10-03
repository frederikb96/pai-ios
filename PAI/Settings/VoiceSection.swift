import PAIKit
import SwiftUI

/// Speech-to-text — ElevenLabs only, no provider abstraction and no fallback branch (see
/// `CLAUDE.md`), so there is exactly one key to configure rather than a provider picker.
struct VoiceSection: View {
    let settings: SettingsStore
    @Environment(AppEnvironment.self) private var environment

    /// `nil` only in the moment between sign-out and a fresh sign-in, when this screen is not
    /// reachable anyway — matching `NotificationsSection`'s own defensive read of the same
    /// optional rather than assuming `SettingsScreen` guarantees it.
    private var voice: VoiceRecorderController? { environment.connection?.voice }

    var body: some View {
        Section {
            SecretField(
                title: "ElevenLabs API Key", identifier: "elevenlabs-key", field: settings.elevenLabsKey)

            // `AVAudioSession` names every input port whether or not the mic has ever been
            // granted, unlike the web's `enumerateDevices()` — so unlike `useAudioInputs.ts`
            // there is no "reveal names" step, and this can be a real picker rather than a device
            // id typed in blind.
            if let voice {
                Picker("Microphone", selection: micDeviceBinding) {
                    Text("System default").tag("")
                    ForEach(voice.availableMicrophones) { option in
                        Text(option.name).tag(option.uid)
                    }
                }
                .accessibilityIdentifier("mic-device")
            }

            Toggle("Silence gate", isOn: gateEnabledBinding)
                .accessibilityIdentifier("silence-gate-enabled")
            if settings.silenceGate.enabled {
                Picker("Threshold", selection: gateModeBinding) {
                    Text("Auto").tag(SilenceGateMode.auto)
                    Text("Manual").tag(SilenceGateMode.manual)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("silence-gate-mode")
                if settings.silenceGate.mode == .manual {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(manualThresholdLabel)
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.textSecondary)
                        Slider(
                            value: manualThresholdBinding,
                            in: Double(
                                SilenceGateSettings.manualRange.lowerBound)...Double(
                                    SilenceGateSettings.manualRange.upperBound),
                            step: 1
                        )
                        .accessibilityIdentifier("silence-gate-threshold")
                    }
                }
            }
        } header: {
            Text("Voice Settings")
        } footer: {
            Text(footerText)
        }
    }

    private var footerText: String {
        "The API key is required for voice transcription. Held encrypted on the server; never shown again once set. "
            + "The silence gate stops sending audio after 5 s of quiet and resumes with the second before speech; "
            + "Auto adapts to the room. Kept on this phone only."
    }

    private var manualThresholdLabel: String {
        "Quiet below \(settings.silenceGate.manualThresholdDb) dBFS"
    }

    private var gateEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.silenceGate.enabled },
            set: { enabled in
                var gate = settings.silenceGate
                gate.enabled = enabled
                settings.setSilenceGate(gate)
            })
    }

    private var gateModeBinding: Binding<SilenceGateMode> {
        Binding(
            get: { settings.silenceGate.mode },
            set: { mode in
                var gate = settings.silenceGate
                gate.mode = mode
                settings.setSilenceGate(gate)
            })
    }

    private var manualThresholdBinding: Binding<Double> {
        Binding(
            get: { Double(settings.silenceGate.manualThresholdDb) },
            set: { value in
                var gate = settings.silenceGate
                gate.manualThresholdDb = Int(value.rounded())
                settings.setSilenceGate(gate)
            })
    }

    private var micDeviceBinding: Binding<String> {
        Binding(get: { settings.micDeviceId }, set: { settings.setMicDeviceId($0) })
    }
}
