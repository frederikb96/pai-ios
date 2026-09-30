import PAIKit
import SwiftUI

/// Arms a grant of every gated secret for the session the new-session screen is about to start —
/// there is no conversation to grant yet, so the backend holds the passphrase until the session
/// the next send creates is up, then grants it. Same shape and passphrase handling as
/// `SecretGrantSheet`: the passphrase lives only in `passphrase` and is cleared on every exit.
struct SecretPregrantSheet: View {
    /// Called with the backend's answer once the grant is armed.
    let onArmed: (SecretPregrantStatus) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment

    @State private var passphrase = ""
    @State private var ttlSeconds = SecretGrantSheet.durationChoices[2].seconds
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var passphraseFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Passphrase", text: $passphrase)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($passphraseFocused)
                        .submitLabel(.go)
                        .onSubmit { Task { await arm() } }
                        .accessibilityIdentifier("secret-pregrant-passphrase")
                } footer: {
                    Text(
                        "Grants every gated secret to the session your next message starts, once it is up. "
                            + "Cancel it from the plus menu before sending.")
                }
                Section {
                    Picker("Access for", selection: $ttlSeconds) {
                        ForEach(SecretGrantSheet.durationChoices, id: \.seconds) { choice in
                            Text(choice.label).tag(choice.seconds)
                        }
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(PaiPalette.Semantic.errorText)
                    }
                }
            }
            .navigationTitle("Grant secrets on start")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Grant all") { Task { await arm() } }
                        .disabled(passphrase.isEmpty || isSubmitting)
                }
            }
        }
        .task {
            // Same settle-then-focus wait as `SecretGrantSheet`, for the same reason.
            try? await Task.sleep(for: .milliseconds(400))
            passphraseFocused = true
        }
        .onDisappear { passphrase = "" }
        .accessibilityIdentifier("secret-pregrant-sheet")
    }

    private func arm() async {
        guard let client = environment.connection?.apiClient, !passphrase.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        let attempted = passphrase
        passphrase = ""
        do {
            let status = try await client.armSecretPregrant(passphrase: attempted, ttlSeconds: ttlSeconds)
            onArmed(status)
            dismiss()
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not arm the grant."
        }
    }
}
