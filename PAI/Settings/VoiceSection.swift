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

            Picker("Language", selection: languageBinding) {
                ForEach(SttLanguage.allCases, id: \.self) { language in
                    Text(languageLabel(language)).tag(language)
                }
            }
            .accessibilityIdentifier("stt-language")

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

            Toggle("Silence Detection", isOn: silenceEnabledBinding)
                .accessibilityIdentifier("silence-detection-enabled")

            if settings.silenceDetectionEnabled {
                VStack(alignment: .leading) {
                    Text("Threshold: \(settings.silenceThreshold, specifier: "%.3f")")
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                    Slider(value: silenceThresholdBinding, in: 0.001...0.05, step: 0.001)
                }
                .accessibilityIdentifier("silence-threshold")

                VStack(alignment: .leading) {
                    Text("Duration: \(settings.silenceDurationMs / 1000, specifier: "%.1f")s")
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                    Slider(value: silenceDurationSecondsBinding, in: 1...30, step: 0.5)
                }
                .accessibilityIdentifier("silence-duration")
            }
        } header: {
            Text("Voice Settings")
        } footer: {
            Text(
                "The API key is required for voice transcription. Held encrypted on the server; never shown again once set."
            )
        }
    }

    private var languageBinding: Binding<SttLanguage> {
        Binding(get: { settings.sttLanguage }, set: { settings.setSttLanguage($0) })
    }

    private var micDeviceBinding: Binding<String> {
        Binding(get: { settings.micDeviceId }, set: { settings.setMicDeviceId($0) })
    }

    private var silenceEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.silenceDetectionEnabled },
            set: { settings.setSilenceDetectionEnabled($0) })
    }

    private var silenceThresholdBinding: Binding<Double> {
        Binding(get: { settings.silenceThreshold }, set: { settings.setSilenceThreshold($0) })
    }

    /// The store keeps milliseconds (matching the wire format); the slider works in seconds,
    /// matching the web's display — the conversion happens only at this one edge.
    private var silenceDurationSecondsBinding: Binding<Double> {
        Binding(
            get: { settings.silenceDurationMs / 1000 },
            set: { settings.setSilenceDurationMs($0 * 1000) })
    }

    private func languageLabel(_ language: SttLanguage) -> String {
        switch language {
        case .auto: return "Auto-detect"
        case .en: return "English"
        case .de: return "German"
        }
    }
}
