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

/// The synced voice settings, in three groups — one per engine the backend drives, since each
/// takes different knobs: Computer (OpenAI Realtime), session replies (ElevenLabs text-to-speech),
/// and dictation (ElevenLabs Scribe). One Save for all three: they are one row on the backend.
struct SpokenVoiceSection: View {
    let store: SpokenVoiceSettingsStore

    private static let openAIVoicesURL = URL(
        string: "https://developers.openai.com/api/docs/guides/realtime-conversations#voice-options")!
    private static let openAIListenURL = URL(string: "https://openai.fm")!
    private static let elevenLabsVoicesURL = URL(string: "https://elevenlabs.io/app/voice-library")!

    var body: some View {
        if store.draft != nil {
            computerGroup
            repliesGroup
            dictationGroup
            Section {
                Button("Save") { Task { await store.save() } }
                    .disabled(!store.canSave)
                    .accessibilityIdentifier("save-voices")
                if let error = store.saveError {
                    Text(error)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                }
            }
        } else {
            Section {
                if let error = store.loadError {
                    Text(error)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                } else {
                    ProgressView()
                }
            } header: {
                Text("Voices")
            }
            .task { if store.loaded == nil { await store.load() } }
        }
    }

    private var computerGroup: some View {
        Section {
            TextField("OpenAI voice name, e.g. cedar", text: field(\.computerVoice))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("computer-voice")
            Link("Voice list", destination: Self.openAIVoicesURL)
            Link("Listen to the voices", destination: Self.openAIListenURL)
            LabeledContent("Speed") {
                TextField("default", text: field(\.computerSpeed))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("computer-speed")
            }
            if !store.isComputerSpeedValid {
                invalid("Speed must be empty or a number between \(bounds(computerSpeedRange)).")
            }
            TextField("Voice instruction — how Computer should sound", text: field(\.computerDelivery), axis: .vertical)
                .lineLimit(2...6)
                .accessibilityIdentifier("computer-delivery")
        } header: {
            Text("Computer — OpenAI Realtime")
        } footer: {
            Text("The voice cannot change once Computer has spoken in a call; a change applies from the next call.")
        }
    }

    private var repliesGroup: some View {
        Section {
            TextField("ElevenLabs voice id", text: field(\.callVoiceId))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("call-voice-id")
            Link("Voice library", destination: Self.elevenLabsVoicesURL)
            LabeledContent("Reply speed") {
                TextField("1", text: field(\.callSpeed))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("call-speed")
            }
            if !store.isSpeedValid {
                invalid("Speed must be a number between \(bounds(callSpeedRange)).")
            }
        } header: {
            Text("Session replies — ElevenLabs")
        } footer: {
            Text(
                "How a session's replies are read aloud in a call. ElevenLabs takes no style text, only a voice and a speed."
            )
        }
    }

    private var dictationGroup: some View {
        Section {
            TextField("Key terms, comma-separated", text: field(\.sttKeyterms), axis: .vertical)
                .lineLimit(1...4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("stt-keyterms")
            if let problem = store.draft?.keytermProblem {
                invalid(problem)
            }
            TextField("Language code — empty detects it", text: field(\.sttLanguage))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("stt-language")
            Toggle("Drop filler words", isOn: noVerbatim)
                .accessibilityIdentifier("stt-no-verbatim")
        } header: {
            Text("Dictation — ElevenLabs Scribe")
        } footer: {
            Text(
                "Applies to every dictation: the composer, a call, the laptop, and re-transcribing a recording. "
                    + "Key terms bias recognition toward names it would otherwise miss, and cost extra. "
                    + "Dropping filler words also drops false starts."
            )
        }
    }

    private func invalid(_ text: String) -> some View {
        Text(text)
            .font(PaiTypography.caption.font)
            .foregroundStyle(PaiPalette.Semantic.errorText)
    }

    private func bounds(_ range: ClosedRange<Double>) -> String {
        "\(range.lowerBound) and \(range.upperBound)"
    }

    private var noVerbatim: Binding<Bool> {
        Binding(
            get: { store.draft?.sttNoVerbatim ?? false },
            set: { store.draft?.sttNoVerbatim = $0 }
        )
    }

    /// One binding builder for every text field — a `Binding` per field written out would be as
    /// many places to get the same `draft == nil` guard right.
    private func field(_ key: WritableKeyPath<SpokenVoiceSettingsDraft, String>) -> Binding<String> {
        Binding(
            get: { store.draft?[keyPath: key] ?? "" },
            set: { store.draft?[keyPath: key] = $0 }
        )
    }
}
