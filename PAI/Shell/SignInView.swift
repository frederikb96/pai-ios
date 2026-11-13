import AuthenticationServices
import PAIKit
import SwiftUI
import UIKit

/// Backend address and sign-in.
///
/// Signing in goes through Zitadel in a system browser sheet and leaves a token set the app
/// renews by itself, so a person signs in once. Pasting a token stays under Advanced, for a
/// machine token and for getting in when the identity provider cannot be reached.
///
/// One screen serves two situations, because the fields are the same and only the explanation
/// differs. They are kept as distinct cases rather than one flag, so a rejected sign-in can say
/// what happened instead of pretending nothing has been set up yet.
struct SignInView: View {

    enum Reason {
        case firstLaunch
        /// The stored credential was refused and could not be renewed; the detail is whatever the
        /// backend said, if anything.
        case rejected(String?)
    }

    let environment: AppEnvironment
    let reason: Reason

    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    @State private var url: String = ""
    @State private var token: String = ""
    @State private var failed = false
    @State private var signingIn = false
    @State private var signInError: String?
    @State private var showsAdvanced = false

    var body: some View {
        NavigationStack {
            Form {
                if case .rejected(let detail) = reason {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("You were signed out.")
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

                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            Spacer()
                            if signingIn {
                                ProgressView()
                            } else {
                                Text("Sign in")
                            }
                            Spacer()
                        }
                    }
                    .disabled(signingIn || url.isEmpty)
                    .accessibilityIdentifier("signin-zitadel")
                } footer: {
                    if let signInError {
                        Text(signInError)
                            .foregroundStyle(PaiPalette.Semantic.errorText)
                    }
                }

                if failed {
                    Text("That backend address could not be used. It needs a scheme, http or https.")
                        .font(.footnote)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                }

                Section {
                    DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                        // Nobody types a JWT, so paste has to be the obvious path — but the field
                        // is still secure, because the value is a long-lived credential.
                        SecureField("Paste an access token", text: $token)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("signin-token")

                        Button("Paste from clipboard") {
                            if let pasted = UIPasteboard.general.string {
                                token = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                        .accessibilityIdentifier("signin-paste")

                        Button("Connect with this token") { connect() }
                            .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || url.isEmpty)
                            .accessibilityIdentifier("signin-connect")
                    }
                    .accessibilityIdentifier("signin-advanced")
                } footer: {
                    if showsAdvanced {
                        Text("A pasted token is not renewed: when it is refused, the app signs out.")
                    }
                }
            }
            .navigationTitle(title)
            .paiListBackground()
        }
        .onAppear {
            // Prefilled rather than blank: the address is almost always already right.
            if url.isEmpty { url = environment.backendURL }
        }
    }

    private var title: String {
        switch reason {
        case .firstLaunch: "Connect"
        case .rejected: "Sign in again"
        }
    }

    /// The authorization-code flow: Zitadel's login in the shared browser session (so a login
    /// already made there is reused), back through the `pai` callback, then the code exchanged
    /// for tokens.
    private func signIn() async {
        let configuration = AppEnvironment.signInConfiguration
        let request = OidcAuthorizationRequest(configuration: configuration)
        signingIn = true
        signInError = nil
        defer { signingIn = false }
        do {
            let callback = try await webAuthenticationSession.authenticate(
                using: request.url,
                callbackURLScheme: configuration.callbackScheme,
                preferredBrowserSession: .shared
            )
            let code = try request.authorizationCode(from: callback)
            let tokens = try await OidcTokenClient(configuration: configuration).exchange(code: code, for: request)
            failed = !environment.signIn(backendURL: url, signIn: tokens)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // Closing the sheet is a choice, not a failure.
        } catch let error as OidcError {
            signInError = error.userMessage
        } catch {
            signInError = error.localizedDescription
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
