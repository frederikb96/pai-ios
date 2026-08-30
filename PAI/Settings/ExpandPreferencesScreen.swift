import PAIKit
import SwiftUI

/// 33 toggles in 11 groups — a drill-in rather than inline in the main Settings form, the same
/// way the web keeps this section collapsed by default. Rendered entirely from
/// `ExpandPreferences.catalogue` rather than a hand-listed set of rows, so a case added to either
/// of the catalogue's source enums appears here automatically.
struct ExpandPreferencesScreen: View {
    let settings: SettingsStore

    var body: some View {
        Form {
            ForEach(ExpandPreferences.catalogue, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.items, id: \.key) { item in
                        Toggle(item.label, isOn: binding(for: item.key))
                            .accessibilityIdentifier("expand-\(item.key)")
                    }
                }
            }
        }
        .paiListBackground()
        .navigationTitle("Message Display")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("expand-preferences-screen")
    }

    private func binding(for key: String) -> Binding<Bool> {
        Binding(
            get: { settings.isExpandEnabled(key) },
            set: { settings.setExpandPreference(key, enabled: $0) })
    }
}
