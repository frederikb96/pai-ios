import PAIKit
import SwiftUI

/// Everything the web's settings panel offers, minus what is out of scope: the VM shell and the
/// apps/memory section.
struct SettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings

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

            Section("Messages") {
                NavigationLink("Message Display") {
                    ExpandPreferencesScreen(settings: settings)
                }
                .accessibilityIdentifier("open-expand-preferences")
            }

            DiagnosticsSection(settings: settings)

            Section {
                Button("Sign out", role: .destructive) { environment.signOut() }
                    .accessibilityIdentifier("sign-out")
            }
        }
        .navigationTitle("Settings")
        .accessibilityIdentifier("settings-screen")
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(get: { settings.theme }, set: { settings.setTheme($0) })
    }
}
