import PAIKit
import SwiftUI

/// Everything the web's settings panel offers, minus the deferred sections.
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
