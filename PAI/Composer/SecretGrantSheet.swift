import PAIKit
import SwiftUI

/// Grants this session's Claude conversation access to every gated secret, for a bounded time —
/// the native counterpart to a Kitty overlay running `secret grant` interactively, for whoever is
/// on the phone instead of the laptop. Sheet shape follows `TemporaryNoteSheet`: a full-screen
/// `NavigationStack` with Cancel/confirm in the toolbar, since this is also the one composer
/// surface where the field being filled in matters more than anything behind it.
///
/// 🚨 The passphrase lives only in `passphrase` below — never Keychain, `UserDefaults`, a draft,
/// or a log line — and is cleared the moment a grant succeeds and again on dismiss, so nothing
/// outlives the sheet that collected it.
struct SecretGrantSheet: View {
    let sessionID: String

    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment

    @State private var passphrase = ""
    @State private var ttlSeconds = Self.durationChoices[2].seconds
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    /// The raw `expires_at` ISO string once granted — `nil` is "still filling in the form", not
    /// "not yet known", since this sheet never shows a prior grant.
    @State private var grantedUntil: String?
    @FocusState private var passphraseFocused: Bool

    /// 60...604800 is the contract's own bound; these are the presets worth offering rather than
    /// a free-form stepper over that whole range.
    private static let durationChoices: [(label: String, seconds: Int)] = [
        ("1 hour", 3600), ("4 hours", 14400), ("24 hours", 86400), ("3 days", 259200), ("7 days", 604800),
    ]

    var body: some View {
        NavigationStack {
            Group {
                if let grantedUntil {
                    grantedView(untilRaw: grantedUntil)
                } else {
                    form
                }
            }
            .navigationTitle("Grant secret access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if grantedUntil == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Grant") { Task { await submit() } }
                            .disabled(passphrase.isEmpty || isSubmitting)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .onAppear { passphraseFocused = true }
        .onDisappear { passphrase = "" }
        .accessibilityIdentifier("secret-grant-sheet")
    }

    private var form: some View {
        Form {
            Section {
                SecureField("Passphrase", text: $passphrase)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($passphraseFocused)
                    .accessibilityIdentifier("secret-grant-passphrase")
            } footer: {
                Text("Unlocks every gated secret for this session's Claude conversation, for the duration below.")
            }

            Section {
                Picker("Access for", selection: $ttlSeconds) {
                    ForEach(Self.durationChoices, id: \.seconds) { choice in
                        Text(choice.label).tag(choice.seconds)
                    }
                }
                .accessibilityIdentifier("secret-grant-duration")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                }
            }

            if isSubmitting {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }
        }
    }

    private func grantedView(untilRaw raw: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(PaiPalette.green500)
            Text("Access granted")
                .font(PaiTypography.bodyEmphasized.font)
                .foregroundStyle(PaiPalette.Semantic.textPrimary)
            Text("Until \(formatted(raw))")
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("secret-grant-success")
    }

    private func submit() async {
        guard let client = environment.connection?.apiClient, !passphrase.isEmpty else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let result = try await client.grantSecretAccess(
                sessionId: sessionID, passphrase: passphrase, ttlSeconds: ttlSeconds)
            switch result {
            case let .granted(expiresAt):
                // Cleared here rather than only on dismiss — a granted passphrase has done its
                // job and has no reason to sit in memory while the confirmation is on screen.
                passphrase = ""
                grantedUntil = expiresAt
            case .wrongPassphrase:
                errorMessage = "Wrong passphrase."
            case .sessionUnavailable:
                errorMessage = "This session isn't running right now — nothing to grant access to."
            case .timedOut:
                errorMessage = "The agent didn't answer in time. Try again."
            }
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not grant access"
        }
    }

    /// Mirrors `SecretField.formatted(_:)` — the backend's six-fractional-digit ISO timestamp
    /// needs `IsoTimestamp`, and the raw string is shown if parsing fails rather than hiding the
    /// expiry entirely.
    private func formatted(_ raw: String) -> String {
        guard let date = IsoTimestamp.date(from: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
