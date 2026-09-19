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

    @State private var showingRecordings = false

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

                // The one way to start a recording tied to no session at all — a meeting, a
                // thought while driving — named and left for later, exactly like any other
                // recording once it is stopped. `RecordingsSheet` itself is what offers "New
                // Recording"; nothing here has a composer to insert into or attach onto.
                Button("Past Recordings") { showingRecordings = true }
                    .accessibilityIdentifier("open-recordings")
                    .sheet(isPresented: $showingRecordings) {
                        RecordingsSheet(controller: voice, onInsertTranscript: { _ in }, onAttach: { _ in })
                    }
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

    private func languageLabel(_ language: SttLanguage) -> String {
        switch language {
        case .auto: return "Auto-detect"
        case .en: return "English"
        case .de: return "German"
        }
    }
}
