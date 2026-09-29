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
///
/// The banner answers two independent questions, kept independent on purpose: *why* it is up
/// (`Severity` — colour, wording, dismissibility) picks nothing about what can be done, and *what
/// can be done right now* (`actionBlock`, driven by `PAIKit`'s `ClaudeAuthPredicates.actionState`)
/// renders identically under every severity. Attaching the action block to one severity instead of
/// sharing it is exactly how "Sign in now" ended up starting a real sign-in with no way to ever
/// show its link.
struct ClaudeAuthBanner: View {
    @Environment(ClaudeAuthStore.self) private var store
    @Environment(ToastCenter.self) private var toasts

    @State private var code = ""
    @State private var copied = false
    /// Warnings are dismissible for as long as the app stays open; a signed-out VM is not,
    /// because nothing works until it is fixed.
    @State private var warningDismissed = false
    @State private var wasSignedOut = false
    @State private var linkExpired = false

    var body: some View {
        Group {
            if let severity {
                bannerBody(severity)
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
        // A login attempt can disappear for reasons besides its agent-side timeout — a success, a
        // deliberate cancel, or a stale poll racing the one that just created it. All of those
        // land well under the deadline, so age is what tells a genuine timeout apart from any of
        // them, rather than a flag this view would have to set at every place a login can end.
        .onChange(of: store.auth.login) { previous, current in
            if let previous, current == nil {
                if ClaudeAuthPredicates.loginLikelyExpired(previous: previous, now: Date().epochMs) {
                    linkExpired = true
                }
            } else if current != nil {
                linkExpired = false
            }
        }
    }

    private var signedOut: Bool { ClaudeAuthPredicates.needsSignIn(store.auth) }
    private var rejected: Bool { ClaudeAuthPredicates.isRejected(store.auth) }
    private var expiring: Bool {
        store.auth.loggedIn == true && ClaudeAuthPredicates.expiresWithinWarning(store.auth, now: Date().epochMs)
    }

    /// Why the banner is up. Colour, wording and dismissibility only — what can be done about it
    /// is `actionBlock`, shared unconditionally below.
    private enum Severity {
        case expiring(notice: String)
        case signedOut(rejected: Bool)

        fileprivate var tone: Tone {
            switch self {
            case .expiring: return .amber
            case .signedOut: return .red
            }
        }

        var iconName: String {
            switch self {
            case .expiring: return "key.fill"
            case .signedOut: return "exclamationmark.circle"
            }
        }

        var dismissible: Bool {
            if case .expiring = self { return true }
            return false
        }

        var accessibilityIdentifier: String {
            switch self {
            case .expiring: return "claude-auth-banner-expiring"
            case .signedOut: return "claude-auth-banner-signed-out"
            }
        }
    }

    private var severity: Severity? {
        if signedOut { return .signedOut(rejected: rejected) }
        if expiring, !warningDismissed {
            // Past its date but nothing has tried to use it yet — which is a real state, since
            // health only turns bad once Anthropic actually refuses a request. "Expires in -4h" is
            // the wrong sentence for it.
            let remainingMs = (store.auth.refreshExpiresAt ?? 0) - Date().epochMs
            let notice =
                remainingMs <= 0
                ? "The Claude sign-in on the VM has expired. Sign in again before starting a session."
                : "The Claude sign-in on the VM expires in \(ClaudeAuthPredicates.formatTimeUntil(remainingMs)). "
                    + "Signing in now avoids sessions stopping mid-conversation."
            return .expiring(notice: notice)
        }
        return nil
    }

    private func bannerBody(_ severity: Severity) -> some View {
        let tone = severity.tone
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: severity.iconName)
                    .foregroundStyle(tone.iconColor)
                header(severity, tone: tone)
                if severity.dismissible {
                    Spacer(minLength: 8)
                    Button {
                        warningDismissed = true
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(tone.iconColor)
                    .accessibilityLabel("Dismiss")
                }
            }
            actionBlock(tone: tone)
        }
        .padding(12)
        .background(tone.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tone.border))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityIdentifier(severity.accessibilityIdentifier)
    }

    @ViewBuilder
    private func header(_ severity: Severity, tone: Tone) -> some View {
        switch severity {
        case .signedOut(let rejected):
            VStack(alignment: .leading, spacing: 2) {
                // Two different things to have gone wrong, and the second one is invisible from
                // the VM's own disk — saying which is what turns a mysterious stuck session into
                // an instruction. Both end the same way, so only the sentence differs.
                Text(rejected ? "Claude is rejecting this VM's sign-in" : "Claude is signed out on the VM")
                    .font(PaiTypography.bodyEmphasized.font)
                    .foregroundStyle(tone.titleColor)
                Text("No session can start or continue until this is done.")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(tone.textColor)
            }
        case .expiring(let notice):
            Text(notice)
                .font(PaiTypography.body.font)
                .foregroundStyle(tone.titleColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What can be done right now, driven by `auth.login` and nothing else — this renders
    /// identically under every severity. The bug this replaced was the button living inside only
    /// the expiring severity's view code, so the link and code field it produces were unreachable
    /// from there: tapping it started a real sign-in on the VM with no way to ever show its link.
    @ViewBuilder
    private func actionBlock(tone: Tone) -> some View {
        switch ClaudeAuthPredicates.actionState(auth: store.auth, busy: store.busy, linkExpired: linkExpired) {
        case .starting:
            HStack(spacing: 6) {
                ProgressView()
                Text("Starting sign-in…")
                    .font(PaiTypography.body.font)
                    .foregroundStyle(tone.textColor)
            }
        case .signIn(let linkExpired):
            VStack(alignment: .leading, spacing: 6) {
                if linkExpired {
                    Text("That sign-in link expired — start again.")
                        .font(PaiTypography.body.font)
                        .foregroundStyle(tone.textColor)
                }
                Button("Sign in now") {
                    self.linkExpired = false
                    Task { await store.startLogin() }
                }
                .buttonStyle(.borderedProminent)
                .tint(tone.accentColor)
            }
        case .controls(let login, let verifying, let busy):
            loginControls(login, verifying: verifying, busy: busy, tone: tone)
        }

        if let problem = store.codeError ?? store.auth.lastError {
            Text(problem)
                .font(PaiTypography.caption.font)
                .foregroundStyle(tone.textColor)
        }
    }

    @ViewBuilder
    private func loginControls(_ login: ClaudeLogin, verifying: Bool, busy: Bool, tone: Tone) -> some View {
        Text("Open the sign-in page, approve it, then paste the code it shows you.")
            .font(PaiTypography.body.font)
            .foregroundStyle(tone.titleColor)

        HStack(spacing: 8) {
            if let url = URL(string: login.url) {
                Link(destination: url) {
                    Label("Open sign-in page", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
                .tint(tone.accentColor)
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
                .disabled(verifying || busy)
                .accessibilityIdentifier("claude-auth-code-field")
            Button {
                Task {
                    let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    if await store.submitCode(loginId: login.id, code: trimmed) {
                        code = ""
                        // Gated on `wasSignedOut` before this fix, so a sign-in started from the
                        // still-logged-in expiring banner got no confirmation at all. That case
                        // needs its own sentence — "sessions are coming back" is wrong when
                        // nothing was ever down.
                        if !wasSignedOut {
                            toasts.show("Signed in to Claude — the VM is good for another month.")
                        }
                    }
                }
            } label: {
                if verifying || busy {
                    ProgressView()
                } else {
                    Text("Sign in")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(tone.accentColor)
            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || verifying || busy)
        }

        Button("Start over with a new link") {
            linkExpired = false
            Task { await store.cancelLogin() }
        }
        .font(PaiTypography.caption.font)
        .foregroundStyle(tone.textColor)
    }
}

/// Colours for one severity — everything the action block needs to match whichever banner it is
/// rendering inside.
fileprivate struct Tone {
    let iconColor: Color
    let titleColor: Color
    let textColor: Color
    let accentColor: Color
    let background: Color
    let border: Color

    static let amber = Tone(
        iconColor: PaiPalette.Semantic.warningText,
        titleColor: PaiPalette.Semantic.warningBannerText,
        textColor: PaiPalette.Semantic.warningText,
        accentColor: PaiPalette.amber500,
        background: PaiPalette.Semantic.warningBackground,
        border: PaiPalette.Semantic.warningBorder
    )

    static let red = Tone(
        iconColor: PaiPalette.Semantic.errorText,
        titleColor: PaiPalette.Semantic.errorBannerText,
        textColor: PaiPalette.Semantic.errorText,
        accentColor: PaiPalette.red500,
        background: PaiPalette.Semantic.errorBackground,
        border: PaiPalette.Semantic.errorBorder
    )
}

extension Date {
    /// Epoch milliseconds, matching the wire's `Double` epoch-ms fields (`refreshExpiresAt` and
    /// friends) — `timeIntervalSince1970` is seconds, and every comparison against those fields
    /// needs the same unit or the warning window is off by 1000x.
    fileprivate var epochMs: Double { timeIntervalSince1970 * 1000 }
}
