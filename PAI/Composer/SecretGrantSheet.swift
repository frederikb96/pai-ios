import PAIKit
import SwiftUI

/// Grants this session's Claude conversation access to gated secrets, for a bounded time — the
/// native counterpart to a Kitty overlay running `secret grant` interactively, for whoever is on
/// the phone instead of the laptop. Sheet shape follows `TemporaryNoteSheet`: a full-screen
/// `NavigationStack` with Cancel/confirm in the toolbar, since this is also the one composer
/// surface where the field being filled in matters more than anything behind it.
///
/// One sheet, two ways to reach it (`ComposerBar` owns both): the plus menu opens it manually at
/// any time, and it pops up by itself when the session is carrying a `SecretPrompt` it raised for
/// itself — the toolbar's leading action becomes `Decline`, which tells the waiting session no,
/// rather than a plain `Cancel`, which tells nobody anything.
///
/// 🚨 The passphrase lives only in `passphrase` below — never Keychain, `UserDefaults`, a draft,
/// or a log line — and is cleared the moment a grant succeeds and again on dismiss, so nothing
/// outlives the sheet that collected it.
struct SecretGrantSheet: View {
    let sessionID: String
    /// The session being granted access, for the sheet's own header — `nil` only in the gap
    /// before the session list has loaded a row for `sessionID`, which the menu entry that opens
    /// this sheet is gated against (`secretGrantable`), so that gap is not expected to reach here.
    let session: Session?
    /// The prompt driving this sheet, if any — `ComposerBar`'s own `currentSecretPrompt`, threaded
    /// through rather than re-read here, since only the caller has the live-status/session
    /// precedence that decides it. `reason` is this sheet's only source for that text: the
    /// `/secret-requests` fetch below answers with names alone.
    let prompt: SecretPrompt?

    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment
    @Environment(MachineStore.self) private var machines

    @State private var passphrase = ""
    @State private var ttlSeconds = Self.durationChoices[2].seconds
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    /// What the sheet has to show before a passphrase is even useful — the gated names the live
    /// conversation actually asked for. Drives which grant action is on offer, not just what the
    /// footer says.
    @State private var requestedAccess: RequestedAccessState = .loading
    /// The raw `expires_at` ISO string once granted — `nil` is "still filling in the form", not
    /// "not yet known", since this sheet never shows a prior grant.
    @State private var grantedUntil: String?
    /// What the grant actually covered — `.all` covers everything, `.requested` only what was
    /// asked for, so this can differ from `requestedAccess`'s own list.
    @State private var grantedNames: [String] = []
    @FocusState private var passphraseFocused: Bool

    /// 60...604800 is the contract's own bound; these are the presets worth offering rather than
    /// a free-form stepper over that whole range.
    private static let durationChoices: [(label: String, seconds: Int)] = [
        ("1 hour", 3600), ("4 hours", 14400), ("24 hours", 86400), ("3 days", 259200), ("7 days", 604800),
    ]

    /// What `getSecretRequests` answered, folded into one state the form switches on.
    private enum RequestedAccessState {
        case loading
        /// Gated names the conversation asked for — legitimately empty, meaning "asked, and
        /// nothing outstanding," distinct from `.notGrantable`.
        case names([String])
        case notGrantable
        case fetchFailed(String)
    }

    /// Whether the live conversation is actually waiting on a grant right now — an empty request
    /// list is a legitimate answer meaning nothing is outstanding, same as `.notGrantable` and
    /// `.fetchFailed`. Drives `Decline`/`Grant`'s presence in the toolbar together, so the two stay
    /// in lockstep without restating the same case match twice.
    private var isPromptPending: Bool {
        if case let .names(names) = requestedAccess { return !names.isEmpty }
        return false
    }

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
                        // `Decline` only while something is actually outstanding — the same
                        // predicate that gates `Grant` below — since telling a session "no" when
                        // it never asked would be answering a question nobody posed.
                        if isPromptPending {
                            Button("Decline", role: .destructive) { Task { await decline() } }
                                .disabled(isSubmitting)
                                .accessibilityIdentifier("secret-grant-decline")
                        } else {
                            Button("Cancel") { dismiss() }
                        }
                    }
                    // Only ever the `.requested` grant — an empty request list offers no toolbar
                    // action at all, so Return (which mirrors this button) cannot fall through to
                    // granting everything. `.grantAllSection` is the only way there.
                    if isPromptPending {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Grant") { Task { await submit(scope: .requested) } }
                                .disabled(passphrase.isEmpty || isSubmitting)
                        }
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .task {
            // Independent of each other — the fetch does not need the passphrase field focused,
            // and the focus delay does not need the fetch to finish first.
            async let requests: Void = loadRequestedAccess()
            async let focus: Void = focusPassphraseAfterTransition()
            _ = await (requests, focus)
        }
        .onDisappear { passphrase = "" }
        .accessibilityIdentifier("secret-grant-sheet")
    }

    // `.onAppear` fires while the sheet's own presentation transition is still animating, and a
    // focus claimed mid-transition is silently dropped — SwiftUI has nothing that signals "the
    // sheet has actually settled," so this waits out the transition rather than racing it. Not
    // verified on a device; flag anew if the delay proves too short or too eager on a real phone.
    private func focusPassphraseAfterTransition() async {
        try? await Task.sleep(for: .milliseconds(400))
        passphraseFocused = true
    }

    private func loadRequestedAccess() async {
        guard let client = environment.connection?.apiClient else {
            requestedAccess = .fetchFailed("Not connected.")
            return
        }
        do {
            switch try await client.getSecretRequests(sessionId: sessionID) {
            case let .names(names): requestedAccess = .names(names)
            case .notGrantable: requestedAccess = .notGrantable
            }
        } catch {
            requestedAccess = .fetchFailed(
                (error as? PaiError)?.userMessage ?? "Could not check what this session has asked for.")
        }
    }

    @ViewBuilder
    private var form: some View {
        Form {
            switch requestedAccess {
            case .loading:
                spinnerSection
            case let .names(names):
                passphraseSection(names: names)
                durationSection
                grantAllSection
            case .notGrantable:
                Section {
                    Text("This session isn't running right now — nothing to grant access to.")
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                }
            case let .fetchFailed(message):
                Section {
                    Text(message)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                    Button("Try again") { Task { await loadRequestedAccess() } }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                }
            }

            if isSubmitting {
                spinnerSection
            }
        }
    }

    private func passphraseSection(names: [String]) -> some View {
        Section {
            SecureField("Passphrase", text: $passphrase)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($passphraseFocused)
                .submitLabel(.go)
                .onSubmit {
                    guard !names.isEmpty else { return }
                    Task { await submit(scope: .requested) }
                }
                .accessibilityIdentifier("secret-grant-passphrase")
        } footer: {
            Text(footerText(names: names))
        }
    }

    private var durationSection: some View {
        Section {
            Picker("Access for", selection: $ttlSeconds) {
                ForEach(Self.durationChoices, id: \.seconds) { choice in
                    Text(choice.label).tag(choice.seconds)
                }
            }
            .accessibilityIdentifier("secret-grant-duration")
        }
    }

    /// The only path to `scope: .all` — deliberately not the toolbar's `Grant` and not wired to
    /// Return, so nothing requested can only ever be granted by an explicit tap here.
    private var grantAllSection: some View {
        Section {
            Button {
                Task { await submit(scope: .all) }
            } label: {
                HStack {
                    Spacer()
                    Text("Grant all")
                    Spacer()
                }
            }
            .disabled(passphrase.isEmpty || isSubmitting)
            .accessibilityIdentifier("secret-grant-all")
        } footer: {
            Text("Grants every gated secret rather than only what was asked for.")
        }
    }

    private var spinnerSection: some View {
        Section {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
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
            if !grantedNames.isEmpty {
                Text(grantedNames.joined(separator: ", "))
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .multilineTextAlignment(.center)
            }
            Text("Until \(formatted(raw))")
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("secret-grant-success")
    }

    private func submit(scope: SecretGrantScope) async {
        guard let client = environment.connection?.apiClient, !passphrase.isEmpty else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let result = try await client.grantSecretAccess(
                sessionId: sessionID, passphrase: passphrase, ttlSeconds: ttlSeconds, scope: scope)
            switch result {
            case let .granted(expiresAt, names):
                // Cleared here rather than only on dismiss — a granted passphrase has done its
                // job and has no reason to sit in memory while the confirmation is on screen.
                passphrase = ""
                grantedNames = names
                grantedUntil = expiresAt
            case .wrongPassphrase:
                errorMessage = "Wrong passphrase."
            case .sessionUnavailable:
                errorMessage = "This session isn't running right now — nothing to grant access to."
            case .nothingRequested:
                // A race: `requestedAccess` said there was something outstanding and there no
                // longer is, by the time this reached the server — re-fetch so the sheet reflects
                // it instead of offering the same stale list again.
                errorMessage = "Nothing to grant anymore — the agent isn't waiting on a gated secret."
                await loadRequestedAccess()
            case let .notAuthorized(message):
                errorMessage = message
            case let .rateLimited(message):
                errorMessage = message
            case let .invalidRequest(message):
                errorMessage = message
            case .timedOut:
                errorMessage = "The agent didn't answer in time. Try again."
            }
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not grant access"
        }
    }

    /// Tells the waiting session no. Dismisses on success (`.declined` and `.alreadyAnswered`
    /// alike — the latter means some other client already answered it, which is just as much a
    /// reason to close this sheet), and leaves it open with a message on a genuine failure so
    /// nothing here is silently lost.
    private func decline() async {
        guard let client = environment.connection?.apiClient else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            _ = try await client.declineSecretPrompt(sessionId: sessionID)
            passphrase = ""
            dismiss()
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not decline."
        }
    }

    /// This sheet's own answer to "which conversation am I about to unlock" — title, session
    /// type and machine, so it is never ambiguous which of possibly several open sessions a Grant
    /// tap affects. `sessionID` alone if the row has not loaded — see `session`'s doc comment for
    /// when that gap is expected.
    private var target: String {
        guard let session else { return sessionID }
        return SessionListDomain.secretGrantTarget(for: session, machines: machines.allMachines)
    }

    private func footerText(names: [String]) -> String {
        guard !names.isEmpty else {
            return "\(target)'s Claude conversation hasn't asked for a gated secret. "
                + "\"Grant all\" unlocks every gated secret for it, for the duration below."
        }
        var text =
            "Unlocks \(names.joined(separator: ", ")) for \(target)'s Claude conversation, "
            + "for the duration below."
        if let reason = prompt?.reason, !reason.isEmpty {
            text += " It asked because: \(reason)."
        }
        return text
    }

    /// Mirrors `SecretField.formatted(_:)` — the backend's six-fractional-digit ISO timestamp
    /// needs `IsoTimestamp`, and the raw string is shown if parsing fails rather than hiding the
    /// expiry entirely.
    private func formatted(_ raw: String) -> String {
        guard let date = IsoTimestamp.date(from: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
