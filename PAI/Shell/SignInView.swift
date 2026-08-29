import PAIKit
import SwiftUI
import UIKit

/// Backend address and token entry.
///
/// One screen serves two situations, because the fields are the same and only the explanation
/// differs. They are kept as distinct cases rather than one flag, so a rejected token can say what
/// happened instead of pretending nothing has been set up yet.
struct SignInView: View {

    enum Reason {
        case firstLaunch
        /// The stored token was refused; the detail is whatever the backend said, if anything.
        case rejected(String?)
    }

    let environment: AppEnvironment
    let reason: Reason

    @State private var url: String = ""
    @State private var token: String = ""
    @State private var failed = false
    @FocusState private var tokenFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if case .rejected(let detail) = reason {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("The saved token was refused.")
                                if let detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(PaiPalette.Semantic.warningText)
                        }
                    }
                }

                Section("Backend") {
                    TextField("https://…", text: $url)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("signin-url")
                }

                Section("Token") {
                    // Nobody types a JWT, so paste has to be the obvious path — but the field is
                    // still secure, because the value is a long-lived credential.
                    SecureField("Paste the access token", text: $token)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($tokenFocused)
                        .accessibilityIdentifier("signin-token")

                    Button("Paste from clipboard") {
                        if let pasted = UIPasteboard.general.string {
                            token = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    .accessibilityIdentifier("signin-paste")
                }

                if failed {
                    Text("That backend address could not be used. It needs a scheme, http or https.")
                        .font(.footnote)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                }

                Section {
                    Button("Connect") { connect() }
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || url.isEmpty)
                        .accessibilityIdentifier("signin-connect")
                }
            }
            .navigationTitle(title)
        }
        .onAppear {
            // Prefilled rather than blank: the address is almost always already right, and on a
            // rejection it is definitely right — only the token needs replacing.
            if url.isEmpty { url = environment.backendURL }
            if case .rejected = reason { tokenFocused = true }
        }
    }

    private var title: String {
        switch reason {
        case .firstLaunch: "Connect"
        case .rejected: "Sign in again"
        }
    }

    private func connect() {
        failed = !environment.signIn(
            backendURL: url,
            token: token.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if !failed { token = "" }
    }
}
