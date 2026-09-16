import PAIKit
import SwiftUI

/// Speech out's own two settings — which ElevenLabs voice call mode speaks replies in, and how
/// fast. Separate from `VoiceSection` (speech-to-text): these configure the reply half of a call,
/// not the dictation half, and the two have nothing else in common.
struct CallModeSection: View {
    let settings: SettingsStore

    var body: some View {
        Section {
            TextField("Voice ID", text: voiceIdBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("call-mode-voice-id")

            VStack(alignment: .leading) {
                Text("Speed: \(settings.ttsSpeechRate, specifier: "%.2f")×")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                Slider(value: speechRateBinding, in: 0.5...2.0, step: 0.05)
            }
            .accessibilityIdentifier("call-mode-speech-rate")
        } header: {
            Text("Call Mode")
        } footer: {
            Text(
                "The ElevenLabs voice id call mode speaks replies in, pasted from your account. Empty uses the default voice for the token."
            )
        }
    }

    private var voiceIdBinding: Binding<String> {
        Binding(get: { settings.ttsVoiceId }, set: { settings.setTtsVoiceId($0) })
    }

    private var speechRateBinding: Binding<Double> {
        Binding(get: { settings.ttsSpeechRate }, set: { settings.setTtsSpeechRate($0) })
    }
}
