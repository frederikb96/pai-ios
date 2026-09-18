import PAIKit
import SwiftUI

/// Everything the web's settings panel offers, minus what is out of scope: the VM shell and the
/// apps/memory section.
struct SettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings

    /// `true` from `CallModeSettingsSheet`: signing out tears down the whole connection the call
    /// itself is running on, which is not a choice to offer from on top of a running call.
    var hidesSignOut = false

    /// What `CallModeSettingsSheet` scrolls to when it opens this screen over the call screen —
    /// the one id both sides share, so the anchor and the target can never drift apart.
    static let callModeSectionAnchorID = "settings-call-mode-section"

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: themeBinding) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Text(theme.rawValue.capitalized).tag(theme)
                    }
                }
                .accessibilityIdentifier("theme-picker")
            }

            SmtpSection(smtp: settings.smtp)

            VoiceSection(settings: settings)

            CallModeSection(settings: settings)
                .id(Self.callModeSectionAnchorID)

            if let connection = environment.connection {
                Section {
                    NavigationLink("Wake Word Samples") {
                        WakeWordSampleScreen(
                            controller: connection.wakeWordSampleCapture, store: connection.wakeWordSamples)
                    }
                    .accessibilityIdentifier("open-wake-word-samples")
                } header: {
                    Text("Wake Word")
                } footer: {
                    Text(
                        "Record real \"Computer\" utterances through this microphone to help retrain the offline wake word."
                    )
                }
            }

            NotificationsSection()


            DiagnosticsSection(settings: settings)

            if !hidesSignOut {
                Section {
                    Button("Sign out", role: .destructive) { Task { await environment.signOut() } }
                        .accessibilityIdentifier("sign-out")
                }
            }
        }
        .paiListBackground()
        .navigationTitle("Settings")
        .accessibilityIdentifier("settings-screen")
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(get: { settings.theme }, set: { settings.setTheme($0) })
    }
}

/// Notifications, and the one control that asks for them.
///
/// Deliberately an explicit opt-in rather than a prompt at launch. iOS shows the system
/// permission alert at most once per install and never again — so asking at a moment the person
/// did not choose spends the only chance there is, over whatever screen they were actually
/// looking at, for a feature they have not asked about yet. Here, the tap is the consent.
private struct NotificationsSection: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Section {
            if let push = environment.connection?.push {
                switch push.registration.status {
                case .notRequested:
                    Button("Enable notifications") {
                        Task {
                            await PushRegistrar.requestAuthorizationIfNeeded(store: push)
                            await push.registerWithBackendIfNeeded()
                        }
                    }
                    .accessibilityIdentifier("enable-notifications")
                case .authorized:
                    LabeledContent(
                        "Notifications", value: push.registration.registeredToken == nil ? "Not yet registered" : "On")
                    ForEach(PushChannel.allCases, id: \.self) { channel in
                        Toggle(isOn: channelBinding(push, channel)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(channel.title)
                                Text(channel.explanation)
                                    .font(PaiTypography.caption.font)
                                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                            }
                        }
                        .accessibilityIdentifier("push-channel-\(channel.rawValue)")
                    }
                case .denied:
                    LabeledContent("Notifications", value: "Off")
                case .failed:
                    LabeledContent("Notifications", value: "Unavailable")
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text(footer)
        }
    }

    /// The toggle reads "receive this", the store holds "muted" — the two are opposites, and this
    /// is the only place they meet. See ``PushChannel`` for why what is stored is the mute.
    private func channelBinding(_ push: PushRegistrationStore, _ channel: PushChannel) -> Binding<Bool> {
        Binding(
            get: { !push.registration.isMuted(channel) },
            set: { wanted in Task { await push.setMuted(!wanted, for: channel) } }
        )
    }

    private var footer: String {
        switch environment.connection?.push.registration.status {
        case .denied:
            "Turned off in iOS Settings. Only the Settings app can turn it back on."
        case .failed:
            "This device could not be registered with Apple. It will try again next launch."
        case .authorized:
            "Alerts about this account reach this device."
        default:
            "Get alerted on this device when something needs you."
        }
    }
}
