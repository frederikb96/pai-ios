import PAIKit
import SwiftUI

/// The VM's Claude sign-in, surfaced app-wide.
///
/// One credential on the VM backs every session, so this belongs above the whole app rather than
/// inside whichever conversation happened to hit the wall first — mounted once from `RootView`,
/// same as the web mounts it above its whole routed app. It appears the moment the agent reports
/// a problem, not only after a session has already failed to start.
///
/// The authorize URL is deliberately not rendered as body text — it is long, and selecting it by
/// hand on a phone keyboard is exactly how a truncated link reached the browser in the web's own
/// history. A button that opens it and a button that copies it are both exact by construction.
struct ClaudeAuthBanner: View {
    @Environment(ClaudeAuthStore.self) private var store
    @Environment(ToastCenter.self) private var toasts

    @State private var code = ""
    @State private var copied = false
    /// Warnings are dismissible for as long as the app stays open; a signed-out VM is not,
    /// because nothing works until it is fixed.
    @State private var warningDismissed = false
    @State private var wasSignedOut = false

    var body: some View {
        Group {
            if signedOut {
                signedOutBanner
            } else if expiring, !warningDismissed {
                expiringBanner
            }
        }
        .onChange(of: store.auth.loggedIn) { _, loggedIn in
            if store.auth.known, loggedIn == false {
                wasSignedOut = true
                warningDismissed = false
            } else if wasSignedOut, loggedIn == true {
                wasSignedOut = false
                code = ""
                toasts.show("Signed in to Claude — your sessions are coming back")
            }
        }
    }

    private var signedOut: Bool { ClaudeAuthPredicates.needsSignIn(store.auth) }
    private var rejected: Bool { ClaudeAuthPredicates.isRejected(store.auth) }
    private var expiring: Bool {
        store.auth.loggedIn == true && ClaudeAuthPredicates.expiresWithinWarning(store.auth, now: Date().epochMs)
    }

    // MARK: - Expiring soon

    private var expiringBanner: some View {
        let remainingMs = (store.auth.refreshExpiresAt ?? 0) - Date().epochMs
        let notice =
            remainingMs <= 0
            ? "The Claude sign-in on the VM has expired. Sign in again before starting a session."
            : "The Claude sign-in on the VM expires in \(ClaudeAuthPredicates.formatTimeUntil(remainingMs)). "
                + "Signing in now avoids sessions stopping mid-conversation."

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "key.fill")
                .foregroundStyle(PaiPalette.Semantic.warningText)
            Text(notice)
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.warningBannerText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                Task { await store.startLogin() }
            } label: {
                if store.busy {
                    ProgressView()
                } else {
                    Text("Sign in now")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(PaiPalette.amber500)
            .disabled(store.busy)

            Button {
                warningDismissed = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(PaiPalette.Semantic.warningText)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(PaiPalette.Semantic.warningBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PaiPalette.Semantic.warningBorder))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityIdentifier("claude-auth-banner-expiring")
    }

    // MARK: - Signed out / rejected

    private var signedOutBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(PaiPalette.Semantic.errorText)
                VStack(alignment: .leading, spacing: 2) {
                    // Two different things to have gone wrong, and the second one is invisible
                    // from the VM's own disk — saying which is what turns a mysterious stuck
                    // session into an instruction. Both end the same way, so only the sentence
                    // differs.
                    Text(rejected ? "Claude is rejecting this VM's sign-in" : "Claude is signed out on the VM")
                        .font(PaiTypography.bodyEmphasized.font)
                        .foregroundStyle(PaiPalette.Semantic.errorBannerText)
                    Text("No session can start or continue until this is done.")
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                }
            }

            if let login = store.auth.login {
                loginControls(login)
            } else {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("Getting a sign-in link…")
                        .font(PaiTypography.body.font)
                        .foregroundStyle(PaiPalette.Semantic.errorBannerText)
                }
            }

            if let problem = store.codeError ?? store.auth.lastError {
                Text(problem)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            }
        }
        .padding(12)
        .background(PaiPalette.Semantic.errorBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PaiPalette.Semantic.errorBorder))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityIdentifier("claude-auth-banner-signed-out")
    }

    @ViewBuilder
    private func loginControls(_ login: ClaudeLogin) -> some View {
        let verifying = login.state == .verifying

        Text("Open the sign-in page, approve it, then paste the code it shows you.")
            .font(PaiTypography.body.font)
            .foregroundStyle(PaiPalette.Semantic.errorBannerText)

        HStack(spacing: 8) {
            if let url = URL(string: login.url) {
                Link(destination: url) {
                    Label("Open sign-in page", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
                .tint(PaiPalette.red500)
            }
            Button {
                UIPasteboard.general.string = login.url
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
        }

        HStack(spacing: 8) {
            TextField("Paste the code here", text: $code)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .textInputAutocapitalization(.never)
                .disabled(verifying || store.busy)
                .accessibilityIdentifier("claude-auth-code-field")
            Button {
                Task {
                    let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    if await store.submitCode(loginId: login.id, code: trimmed) { code = "" }
                }
            } label: {
                if verifying || store.busy {
                    ProgressView()
                } else {
                    Text("Sign in")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(PaiPalette.red500)
            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || verifying || store.busy)
        }

        Button("Start over with a new link") {
            Task { await store.cancelLogin() }
        }
        .font(PaiTypography.caption.font)
        .foregroundStyle(PaiPalette.Semantic.errorText)
    }
}

extension Date {
    /// Epoch milliseconds, matching the wire's `Double` epoch-ms fields (`refreshExpiresAt` and
    /// friends) — `timeIntervalSince1970` is seconds, and every comparison against those fields
    /// needs the same unit or the warning window is off by 1000x.
    fileprivate var epochMs: Double { timeIntervalSince1970 * 1000 }
}
