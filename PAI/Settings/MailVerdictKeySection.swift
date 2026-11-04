import PAIKit
import SwiftUI

/// The MailVerdict key of this device. It lives in this device's Keychain only (`MailVerdictKeyStore`)
/// and is attached to a message sent to the MailVerdict assistant; PAI Cloud holds it in memory for
/// that one reply and never stores it, so nothing here is synced and nothing can read it back.
struct MailVerdictKeySection: View {
    @State private var draft = ""
    @State private var isSet = MailVerdictKeyStore().read() != nil
    @State private var failure: String?

    var body: some View {
        Section {
            HStack {
                Text("Key on this device")
                Spacer()
                Text(isSet ? "Set" : "Not set")
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .accessibilityIdentifier("mailverdict-key-status")
            }
            SecureField(isSet ? "Replace the key" : "Paste the key", text: $draft)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("mailverdict-key-field")
            Button("Save key") { save() }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("mailverdict-key-save")
            if isSet {
                Button("Remove key", role: .destructive) { remove() }
                    .accessibilityIdentifier("mailverdict-key-remove")
            }
            if let failure {
                Text(failure)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            }
        } header: {
            Text("MailVerdict")
        } footer: {
            Text(
                "Kept in this device's Keychain only. It is sent with each message to the MailVerdict assistant and never stored by PAI Cloud or synced."
            )
        }
        .id(FixtureScrollAnchor.mailVerdictKey.rawValue)
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MailVerdictKeyStore().write(key) else {
            failure = "Could not save the key to the Keychain."
            return
        }
        draft = ""
        failure = nil
        isSet = true
    }

    private func remove() {
        guard MailVerdictKeyStore().write(nil) else {
            failure = "Could not remove the key from the Keychain."
            return
        }
        failure = nil
        isSet = false
    }
}
