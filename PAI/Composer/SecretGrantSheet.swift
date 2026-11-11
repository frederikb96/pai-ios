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
/// Grant and Grant all close the sheet at once and hand the request to `SecretGrantRunStore`,
/// which reports success as a toast; a failure brings this sheet back with the reason
/// (`ComposerBar` re-presents it, this view shows `failures`).
///
/// 🚨 The passphrase lives only in `passphrase` below — never Keychain, `UserDefaults`, a draft,
/// or a log line — and is cleared the moment it is handed to the request and again on dismiss, so
/// nothing outlives the sheet that collected it.
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
    @Environment(SecretGrantRunStore.self) private var grantRuns
    @Environment(ToastCenter.self) private var toasts

    @State private var passphrase = ""
    @State private var ttlSeconds = Self.durationChoices[2].seconds
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    /// What the sheet has to show before a passphrase is even useful — the gated names the live
    /// conversation actually asked for. Drives which grant action is on offer, not just what the
    /// footer says.
    @State private var requestedAccess: RequestedAccessState = .loading
    @FocusState private var passphraseFocused: Bool

    /// 60...604800 is the contract's own bound; these are the presets worth offering rather than
    /// a free-form stepper over that whole range. `SecretPregrantSheet` offers the same ones.
    static let durationChoices: [(label: String, seconds: Int)] = [
        ("1 hour", 3600), ("4 hours", 14400), ("24 hours", 86400), ("3 days", 259200), ("7 days", 604800),
    ]

    /// What `getSecretRequests` answered, folded into one state the form switches on.
    private enum RequestedAccessState {
        case loading
        /// Gated names the conversation asked for — legitimately empty, meaning "asked, and
        /// nothing outstanding," distinct from `.notGrantable`. `vault4` is the subset held in
        /// vault 4.
        case names([String], vault4: [String])
        case notGrantable
        case fetchFailed(String)
    }

    /// Whether the live conversation is actually waiting on a grant right now — an empty request
    /// list is a legitimate answer meaning nothing is outstanding, same as `.notGrantable` and
    /// `.fetchFailed`. Drives `Decline`/`Grant`'s presence in the toolbar together, so the two stay
    /// in lockstep without restating the same case match twice.
    /// A session that has not come up has no conversation to grant: the backend holds a grant of
    /// everything and applies it once the session is up, so nothing is asked of it first.
    private var waitsForStart: Bool { session?.state == .starting }

    /// A grant for this session is still running from an earlier submit of this sheet.
    private var isGranting: Bool { grantRuns.inFlight.contains(sessionID) }

    private var isPromptPending: Bool {
        if case let .names(names, _) = requestedAccess { return !names.isEmpty }
        return false
    }

    var body: some View {
        NavigationStack {
            form
                .navigationTitle("Grant secret access")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
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
                    // Only ever the `.requested` grant; with nothing requested, `.grantAllSection`
                    // and Return both grant everything instead.
                    if isPromptPending {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Grant") { submit(scope: .requested) }
                                .disabled(passphrase.isEmpty || isSubmitting || isGranting)
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
        .onChange(of: grantRuns.failures[sessionID], initial: true) { _, _ in
            if let message = grantRuns.takeFailure(sessionId: sessionID) { errorMessage = message }
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
        if waitsForStart {
            requestedAccess = .names([], vault4: [])
            return
        }
        guard let client = environment.connection?.apiClient else {
            requestedAccess = .fetchFailed("Not connected.")
            return
        }
        do {
            switch try await client.getSecretRequests(sessionId: sessionID) {
            case let .names(names, vault4): requestedAccess = .names(names, vault4: vault4)
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
            case let .names(names, vault4):
                passphraseSection(names: names, vault4: vault4)
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

            if isSubmitting || isGranting {
                spinnerSection
            }
        }
    }

    private func passphraseSection(names: [String], vault4: [String]) -> some View {
        Section {
            SecureField("Passphrase", text: $passphrase)
                // Marks the field as a password so the keyboard offers the Passwords key and a
                // credential provider can fill it — the passphrase is long and generated, not typed.
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($passphraseFocused)
                .submitLabel(.go)
                // Return grants what was asked for, or everything when nothing was — the same
                // answer the web's Enter gives.
                .onSubmit { submit(scope: names.isEmpty ? .all : .requested) }
                .accessibilityIdentifier("secret-grant-passphrase")
        } footer: {
            footer(names: names, vault4: vault4)
        }
    }

    /// The sentence under the passphrase field. A vault-4 name the session asked for is drawn as a
    /// magenta chip among the others, with a notice saying what the grant now covers; a list with
    /// none stays one plain sentence.
    @ViewBuilder
    private func footer(names: [String], vault4: [String]) -> some View {
        let askedVault4 = names.filter { vault4.contains($0) }
        if askedVault4.isEmpty {
            Text(footerText(names: names))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(footerText(names: names, listsNames: false))
                NoteInlineFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(names, id: \.self) { name in
                        if vault4.contains(name) {
                            Vault4NameChip(name: name)
                        } else {
                            Text(name)
                                .font(PaiTypography.caption.font.monospaced())
                                .foregroundStyle(PaiPalette.Semantic.textSecondary)
                        }
                    }
                }
                .accessibilityIdentifier("secret-grant-names")
                Vault4Notice(names: askedVault4)
            }
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

    /// `scope: .all` — also what Return does while nothing is requested.
    private var grantAllSection: some View {
        Section {
            Button {
                submit(scope: .all)
            } label: {
                HStack {
                    Spacer()
                    Text("Grant all")
                    Spacer()
                }
            }
            .disabled(passphrase.isEmpty || isSubmitting || isGranting)
            .accessibilityIdentifier("secret-grant-all")
        } footer: {
            Text("Grants everything in the gated store except vault 4, rather than only what was asked for.")
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

    /// Hands the passphrase to the background request and closes; the outcome arrives as a toast
    /// or as this sheet coming back with the reason.
    private func submit(scope: SecretGrantScope) {
        guard !passphrase.isEmpty, !isGranting else { return }
        grantRuns.start(
            sessionId: sessionID, passphrase: passphrase, ttlSeconds: ttlSeconds, scope: scope, toasts: toasts)
        passphrase = ""
        dismiss()
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

    /// `listsNames: false` leaves the names out of the sentence, for the caller that draws them as
    /// chips under it.
    private func footerText(names: [String], listsNames: Bool = true) -> String {
        if waitsForStart {
            return "\(target)'s Claude conversation is still starting. "
                + "\"Grant all\" unlocks everything except vault 4 for it once it is up, for the duration below."
        }
        guard !names.isEmpty else {
            return "\(target)'s Claude conversation hasn't asked for a gated secret. "
                + "\"Grant all\" unlocks everything except vault 4 for it, for the duration below."
        }
        var text =
            (listsNames
                ? "Unlocks \(names.joined(separator: ", ")) for \(target)'s Claude conversation, "
                : "Unlocks these for \(target)'s Claude conversation, ")
            + "for the duration below."
        if let reason = prompt?.reason, !reason.isEmpty {
            text += " It asked because: \(reason)."
        }
        return text
    }
}

/// A vault-4 name: the tag and the name in the vault-4 colours, so it cannot be mistaken for an
/// ordinary gated name. Mirrors the web's `SecretGrantDialog` chip.
struct Vault4NameChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            Text("VAULT 4")
                .font(PaiTypography.caption.font.weight(.semibold))
            Text(name)
                .font(PaiTypography.caption.font.monospaced())
        }
        .foregroundStyle(PaiPalette.Vault4.text)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(PaiPalette.Vault4.background)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(PaiPalette.Vault4.ring, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Vault 4: \(name)")
        .accessibilityIdentifier("vault4-chip")
    }
}

/// What a grant covers when the session named a vault-4 name: said once, in the vault-4 colours,
/// with a bar on the left, since both grant buttons include the name.
struct Vault4Notice: View {
    let names: [String]

    private var message: AttributedString {
        let pronoun = names.count == 1 ? "it" : "them"
        var lead = AttributedString("Vault 4 holds high-stakes secrets. ")
        lead.inlinePresentationIntent = .stronglyEmphasized
        let covers = "A grant covers \(names.joined(separator: ", ")) only because this session named \(pronoun); "
        let both = "Grant and Grant all both include \(pronoun). Decline if you did not expect this."
        lead.append(AttributedString(covers + both))
        return lead
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(PaiPalette.Vault4.ring).frame(width: 4)
            Text(message)
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Vault4.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .background(PaiPalette.Vault4.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("vault4-notice")
    }
}
