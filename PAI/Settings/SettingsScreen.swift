import PAIKit
import SwiftUI

/// What the web's settings panel offers, minus what is out of scope: the VM shell, the memory
/// pipeline and the keyboard shortcuts. A topic with many controls (alert routing, alert mail)
/// opens on a screen of its own from a row, as on the web.
struct SettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings

    var hidesSignOut = false

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

            // Alerts, their routing and their mail are the owner's, as on the web.
            if environment.connection?.me.isGuest != true {
                AlertsSection(alerts: settings.alerts, routing: settings.alertRouting, smtp: settings.smtp)
            }

            // What scheduled agents are told is the owner's, as with the alerts.
            if environment.connection?.me.isGuest != true {
                StatusMessageSection(store: settings.statusMessage)
            }

            NotificationsSection()

            VoiceSection(settings: settings)

            ComputerSection(settings: settings)

            HistorySection(settings: settings)

            NotesCacheSection(settings: settings)

            LastCrashSection()

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

/// This device's notifications: whether it can receive a push, and which channels it takes.
///
/// A notification is always kept in the notifications screen. A push is the delivery of one to
/// this device, and a channel is what this device can switch off; the choice is stored on the
/// server per device. Both channels off means no push here, and nothing in the notifications
/// screen changes.
///
/// Enabling is an explicit opt-in rather than a prompt at launch. iOS shows the system permission
/// alert at most once per install and never again — so asking at a moment the person did not
/// choose spends the only chance there is, over whatever screen they were actually looking at,
/// for a feature they have not asked about yet. Here, the tap is the consent.
private struct NotificationsSection: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Section {
            if let push = environment.connection?.push, let channels = environment.connection?.pushChannels {
                switch push.registration.status {
                case .notRequested:
                    Button("Enable push on this device") {
                        Task {
                            await PushRegistrar.requestAuthorizationIfNeeded(store: push)
                            await push.registerWithBackendIfNeeded()
                        }
                    }
                    .accessibilityIdentifier("enable-notifications")
                case .authorized:
                    LabeledContent(
                        "Push on this device",
                        value: push.registration.deviceStatusText(offeredChannelIds: channels.offeredIds))
                    ForEach(channels.rows(muted: push.registration.mutedChannels)) { channel in
                        Toggle(isOn: channelBinding(push, channel.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(channel.label)
                                Text(channel.description)
                                    .font(PaiTypography.caption.font)
                                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                            }
                        }
                        .accessibilityIdentifier("push-channel-\(channel.id)")
                    }
                case .denied:
                    LabeledContent("Push on this device", value: "Off")
                case .failed:
                    LabeledContent("Push on this device", value: "Unavailable")
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text(footer)
        }
        .task { await environment.connection?.pushChannels.load() }
    }

    /// The toggle reads "receive this", the store holds "muted" — the two are opposites, and this
    /// is the only place they meet. See ``PushRegistration/mutedChannels`` for why what is stored
    /// is the mute.
    private func channelBinding(_ push: PushRegistrationStore, _ channelId: String) -> Binding<Bool> {
        Binding(
            get: { !push.registration.isMuted(channelId) },
            set: { wanted in Task { await push.setMuted(!wanted, forChannel: channelId) } }
        )
    }

    private var footer: String {
        switch environment.connection?.push.registration.status {
        case .denied:
            "Turned off in iOS Settings. Only the Settings app can turn it back on."
        case .failed:
            "This device could not be registered with Apple. It will try again next launch."
        case .authorized:
            "Everything is always kept in the notifications screen. These switches decide what this device also gets as a push."
        default:
            "Get a push on this device when something needs you."
        }
    }
}
