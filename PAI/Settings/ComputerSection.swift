import PAIKit
import SwiftUI

/// What Computer speaks with and what it acts through.
///
/// Every value here is one backend setting read by every transport — the phone, the browser and
/// a plain phone call all get whatever is set here, because the backend is the only thing that
/// speaks. There is deliberately no per-client override.
struct ComputerSection: View {
    let settings: SettingsStore

    var body: some View {
        Section {
            SecretField(
                title: "Home Assistant token", identifier: "home-assistant-token",
                field: settings.homeAssistantToken)
            SecretField(
                title: "Todoist token", identifier: "todoist-token", field: settings.todoistToken)
        } header: {
            Text("Computer's Keys")
        } footer: {
            Text(
                "Lights, automations and tasks only work once these are set. Held encrypted on the server; never shown again."
            )
        }

        SpokenVoiceSection(store: settings.voices)
    }
}

/// How the two spoken voices sound. Two synthesisers, so two independent halves: Computer speaks
/// through OpenAI Realtime, which names a voice and has no speed parameter at all — delivery
/// there is words, told to the model. A session's call-mode replies go through ElevenLabs, which
/// takes a voice id and a speed and no instructions.
struct SpokenVoiceSection: View {
    let store: SpokenVoiceSettingsStore

    var body: some View {
        Section {
            if store.draft != nil {
                TextField("OpenAI voice name, e.g. marin", text: computerVoice)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("computer-voice")

                TextField(
                    "Speak quickly and get to the point.", text: computerDelivery,
                    axis: .vertical
                )
                .lineLimit(2...4)
                .accessibilityIdentifier("computer-delivery")

                TextField("ElevenLabs voice id", text: callVoiceId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("call-voice-id")

                LabeledContent("Reply speed") {
                    TextField("1", text: callSpeed)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("call-speed")
                }

                if !store.isSpeedValid {
                    Text("Speed must be a number between \(speedBounds).")
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                }

                Button("Save") { Task { await store.save() } }
                    .disabled(!store.canSave)
                    .accessibilityIdentifier("save-voices")
            } else if store.isLoading {
                ProgressView()
            } else if let error = store.loadError {
                Text(error)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            }

            if let error = store.saveError {
                Text(error)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            }
        } header: {
            Text("Computer's Voice")
        } footer: {
            Text(
                "An empty voice leaves the choice to whatever speaks. How Computer speaks is told to the model, because that voice has no speed setting."
            )
        }
        .task { if store.loaded == nil { await store.load() } }
    }

    private var speedBounds: String {
        "\(callSpeedRange.lowerBound) and \(callSpeedRange.upperBound)"
    }

    private var computerVoice: Binding<String> {
        field(\.computerVoice)
    }

    private var computerDelivery: Binding<String> {
        field(\.computerDelivery)
    }

    private var callVoiceId: Binding<String> {
        field(\.callVoiceId)
    }

    private var callSpeed: Binding<String> {
        field(\.callSpeed)
    }

    /// One binding builder for four identical text fields — a `Binding` per field written out
    /// would be four places to get the same `draft == nil` guard right.
    private func field(_ key: WritableKeyPath<SpokenVoiceSettingsDraft, String>) -> Binding<String> {
        Binding(
            get: { store.draft?[keyPath: key] ?? "" },
            set: { store.draft?[keyPath: key] = $0 }
        )
    }
}
