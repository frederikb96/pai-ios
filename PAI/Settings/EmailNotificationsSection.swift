import PAIKit
import SwiftUI

/// The person's e-mail switch: whether an agent's notification to them may also go out by e-mail.
/// A setting of the person, the same on every device. Hidden until the backend has answered, so it
/// never shows a state the server does not have.
struct EmailNotificationsSection: View {
    let store: UserSettingsStore
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        if let settings = store.settings {
            Section {
                Toggle(
                    "E-mail notifications",
                    isOn: Binding(
                        get: { settings.emailNotifications },
                        set: { enabled in
                            Task {
                                if !(await store.update(UserSettingsPatch(emailNotifications: enabled))),
                                    let message = store.errorMessage
                                {
                                    toasts.show(message, kind: .error)
                                }
                            }
                        })
                )
                .accessibilityIdentifier("email-notifications-toggle")
            } header: {
                Text("E-mail")
            } footer: {
                Text("Let an agent's notification to you also go out by e-mail.")
            }
            .id(FixtureScrollAnchor.emailNotifications.rawValue)
            .fixtureFact("emailNotifications", settings.emailNotifications ? "on" : "off")
        }
    }
}
