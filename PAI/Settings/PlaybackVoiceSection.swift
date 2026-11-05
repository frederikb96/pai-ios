import PAIKit
import SwiftUI

/// The voice and speed replies are read aloud with: the person's own, the same on every device.
/// The owner's default voice, the backup voice and its budget are set on the web.
///
/// Hidden until the backend has answered with both the person's settings and the voice list
/// (`SettingsScreen` loads the list), so it never shows a state the server does not have.
struct PlaybackVoiceSection: View {
    let userSettings: UserSettingsStore
    let voices: PlaybackVoicesStore

    @Environment(ToastCenter.self) private var toasts
    /// "Another voice id…" picked: the typed id is shown even before it is saved.
    @State private var customPicked = false
    @State private var typed = ""
    @FocusState private var typing: Bool

    private static let voiceLibraryURL = URL(string: "https://elevenlabs.io/app/voice-library")!

    var body: some View {
        if let settings = userSettings.settings, let list = voices.voices {
            Section {
                Picker("Your voice", selection: selectionBinding(settings, list)) {
                    Text("Default (\(list.defaultVoiceLabel))").tag(PlaybackVoiceSelection.defaultVoice)
                    ForEach(list.elevenlabs) { voice in
                        Text(voice.label).tag(PlaybackVoiceSelection.listed(voice.voiceId))
                    }
                    Text("Another voice id…").tag(PlaybackVoiceSelection.custom)
                }
                .accessibilityIdentifier("playback-voice")
                if shownSelection(settings, list) == .custom {
                    TextField("ElevenLabs voice id", text: $typed)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($typing)
                        .onSubmit { Task { await commitTyped(settings) } }
                        .accessibilityIdentifier("playback-voice-id")
                    Link("ElevenLabs voice library", destination: Self.voiceLibraryURL)
                }
                Button(tryTitle) {
                    // A reply in hand would talk over the sample.
                    PlaybackController.shared.pause()
                    Task { await voices.tryVoice(triedVoice(settings)) }
                }
                .disabled(voices.sampleState == .loading)
                .accessibilityIdentifier("playback-voice-try")
                if let error = voices.sampleError {
                    Text(error)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                }
                Picker("Your speed", selection: speedBinding(settings)) {
                    ForEach(PlaybackModel.speeds, id: \.self) { speed in
                        Text("\(speed.formatted())×").tag(speed)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("playback-speed")
            } header: {
                Text("Playback voices")
            } footer: {
                Text(
                    "Your voice reads replies aloud for you, on every device; Default is the voice the owner set for everyone. Your speed is also set by the speed buttons in the player."
                )
            }
            .id(FixtureScrollAnchor.playbackVoice.rawValue)
            .fixtureFact("playbackVoice", factLabel(settings, list))
            .onChange(of: settings.playbackVoiceId) { _, _ in voices.stopSample() }
            .onDisappear { voices.stopSample() }
        }
    }

    private var tryTitle: String {
        switch voices.sampleState {
        case .idle: "Try voice"
        case .loading: "Loading…"
        case .playing: "Stop"
        }
    }

    private func shownSelection(_ settings: UserSettings, _ list: PlaybackVoices) -> PlaybackVoiceSelection {
        customPicked ? .custom : .of(settings.playbackVoiceId, listed: list.elevenlabs)
    }

    private func factLabel(_ settings: UserSettings, _ list: PlaybackVoices) -> String {
        switch shownSelection(settings, list) {
        case .defaultVoice: "Default (\(list.defaultVoiceLabel))"
        case let .listed(id): list.elevenlabs.first { $0.voiceId == id }?.label ?? id
        case .custom: "custom"
        }
    }

    /// The voice Try plays: what is typed while a custom id is being entered, else the saved one;
    /// `nil` is the default voice.
    private func triedVoice(_ settings: UserSettings) -> String? {
        let id = customPicked ? typed.trimmingCharacters(in: .whitespaces) : settings.playbackVoiceId
        return id?.isEmpty == false ? id : nil
    }

    private func selectionBinding(_ settings: UserSettings, _ list: PlaybackVoices) -> Binding<PlaybackVoiceSelection> {
        Binding(
            get: { shownSelection(settings, list) },
            set: { picked in
                switch picked {
                case .defaultVoice:
                    customPicked = false
                    Task { await save(UserSettingsPatch(playbackVoice: .clear)) }
                case let .listed(id):
                    customPicked = false
                    Task { await save(UserSettingsPatch(playbackVoice: .set(id))) }
                case .custom:
                    customPicked = true
                    typed = settings.playbackVoiceId ?? ""
                }
            })
    }

    private func speedBinding(_ settings: UserSettings) -> Binding<Double> {
        Binding(
            get: { settings.playbackSpeed },
            set: { speed in Task { await save(UserSettingsPatch(playbackSpeed: speed)) } })
    }

    /// A typed id is taken once the field is submitted; empty means the default voice.
    private func commitTyped(_ settings: UserSettings) async {
        let next = typed.trimmingCharacters(in: .whitespaces)
        guard next != (settings.playbackVoiceId ?? "") else { return }
        await save(UserSettingsPatch(playbackVoice: next.isEmpty ? .clear : .set(String(next.prefix(64)))))
    }

    private func save(_ patch: UserSettingsPatch) async {
        if !(await userSettings.update(patch)), let message = userSettings.errorMessage {
            toasts.show(message, kind: .error)
        }
    }
}
