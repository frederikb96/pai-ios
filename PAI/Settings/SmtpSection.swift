import PAIKit
import SwiftUI

/// "Alert Mail" — lets the backend email Freddy when something breaks. Server-persisted,
/// draft-and-save: nothing here is sent until Save, except the password, which is its own
/// write-only secret with its own immediate Save/Clear (`SecretField`).
struct SmtpSection: View {
    let smtp: SmtpSettingsStore

    var body: some View {
        Section {
            if let draft = smtp.draft {
                loadedContent(draft)
            } else if smtp.isLoading {
                ProgressView()
            } else if let error = smtp.loadError {
                Text(error)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            }
        } header: {
            Text("Alert Mail")
        } footer: {
            Text("Lets PAI email you when something breaks.")
        }
        .task {
            if smtp.draft == nil { await smtp.load() }
        }
    }

    @ViewBuilder
    private func loadedContent(_ draft: SmtpSettingsDraft) -> some View {
        Toggle("Enabled", isOn: bindingToDraft(\.enabled, fallback: draft))
            .accessibilityIdentifier("smtp-enabled")

        // `LabeledContent` rather than a bare `TextField`: a text field's title is only its
        // placeholder, so it vanishes the moment the field holds anything — leaving a configured
        // server as a column of unlabelled strings with no way to tell a host from a recipient.
        LabeledContent("Host") {
            TextField("mail.example.com", text: bindingToDraft(\.host, fallback: draft))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("smtp-host")
        }

        LabeledContent("Port") {
            TextField("587", value: bindingToDraft(\.port, fallback: draft), format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("smtp-port")
        }
        if !smtp.isPortValid {
            Text("Port must be between 1 and 65535.")
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.errorText)
        }

        Picker("Security", selection: bindingToDraft(\.security, fallback: draft)) {
            ForEach(securityOptions(current: draft.security), id: \.self) { option in
                Text(securityLabel(option)).tag(option)
            }
        }
        .accessibilityIdentifier("smtp-security")

        LabeledContent("Username") {
            TextField("", text: bindingToDraft(\.username, fallback: draft))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("smtp-username")
        }

        SecretField(title: "Password", identifier: "smtp-password", field: smtp.password)

        LabeledContent("From") {
            TextField("Defaults to the username", text: bindingToDraft(\.fromAddress, fallback: draft))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("smtp-from")
        }

        LabeledContent("Recipient") {
            TextField("", text: bindingToDraft(\.recipient, fallback: draft))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("smtp-recipient")
        }
        if !smtp.isRecipientValid {
            Text("Recipient must contain an @.")
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.errorText)
        }

        Button("Save") { Task { await smtp.save() } }
            .disabled(!smtp.canSave)
            .accessibilityIdentifier("smtp-save")
        if let error = smtp.saveError {
            Text(error)
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.errorText)
        }

        sendTestRow
    }

    @ViewBuilder
    private var sendTestRow: some View {
        Button("Send test mail") { Task { await smtp.sendTest() } }
            .disabled(!smtp.canSendTest)
            .accessibilityIdentifier("smtp-send-test")

        if smtp.isDirty {
            Text("Save before sending a test — it uses what is stored, not this draft.")
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textFaint)
        }

        switch smtp.testOutcome {
        case .sent:
            Text("Test mail sent.")
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textPrimary)
        case .failed(let message):
            Text(message)
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.errorText)
        case nil:
            EmptyView()
        }
    }

    private func bindingToDraft<T>(
        _ keyPath: WritableKeyPath<SmtpSettingsDraft, T>, fallback: SmtpSettingsDraft
    ) -> Binding<T> {
        Binding(
            get: { smtp.draft?[keyPath: keyPath] ?? fallback[keyPath: keyPath] },
            set: { smtp.draft?[keyPath: keyPath] = $0 }
        )
    }

    /// `.unrecognized` has no case in the picker's fixed three options; a draft that already
    /// holds one (an unfamiliar value the server sent) gets it appended so the picker never shows
    /// a selection that matches none of its own options.
    private func securityOptions(current: SmtpSecurity) -> [SmtpSecurity] {
        var options: [SmtpSecurity] = [.ssl, .starttls, .none]
        if case .unrecognized = current {
            options.append(current)
        }
        return options
    }

    private func securityLabel(_ security: SmtpSecurity) -> String {
        switch security {
        case .ssl: return "SSL"
        case .starttls: return "STARTTLS"
        case .none: return "None"
        case .unrecognized(let raw): return raw
        }
    }
}
