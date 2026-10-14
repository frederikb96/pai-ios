import PAIKit
import SwiftUI

/// The status message the backend appends to every scheduled-agent run, so unattended agents know
/// about an absence or a change of plans. Draft-and-save; whether it is in effect is the server's
/// `active`.
struct StatusMessageSection: View {
    @Bindable var store: StatusMessageStore

    var body: some View {
        Section {
            if store.message != nil {
                loadedContent
            } else if let error = store.errorMessage {
                Text(error)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            } else {
                ProgressView()
            }
        } header: {
            Text("Status message")
        } footer: {
            Text("Added to the prompt of every scheduled agent run, e.g. that you are away and how to handle things.")
        }
        .task { await store.load() }
    }

    @ViewBuilder
    private var loadedContent: some View {
        TextField("Nothing set", text: draftBinding, axis: .vertical)
            .lineLimit(3...10)
            .accessibilityIdentifier("status-message-text")
        Text("\(store.draftText.count) / \(StatusMessage.maxTextLength)")
            .font(PaiTypography.caption.font)
            .foregroundStyle(PaiPalette.Semantic.textFaint)

        Toggle("Until", isOn: $store.hasExpiry)
            .accessibilityIdentifier("status-message-expiry-toggle")
        if store.hasExpiry {
            DatePicker("Ends", selection: $store.draftExpiry, displayedComponents: [.date, .hourAndMinute])
                .accessibilityIdentifier("status-message-expiry")
        }

        Button("Save") { Task { await store.save() } }
            .disabled(!store.canSave)
            .accessibilityIdentifier("status-message-save")
        Button("Clear", role: .destructive) { Task { await store.clear() } }
            .disabled(!store.canClear)
            .accessibilityIdentifier("status-message-clear")

        Text(stateLine)
            .font(PaiTypography.caption.font)
            .foregroundStyle(PaiPalette.Semantic.textMuted)
            .accessibilityIdentifier("status-message-state")
        if let error = store.errorMessage {
            Text(error)
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.errorText)
        }
    }

    private var draftBinding: Binding<String> {
        Binding(get: { store.draftText }, set: { store.setDraftText($0) })
    }

    private var stateLine: String {
        guard let message = store.message, message.text != nil else { return "No message set." }
        let expiry = store.expiryDate.map { $0.formatted(date: .abbreviated, time: .shortened) }
        if message.active {
            return expiry.map { "Active, until \($0)." } ?? "Active, with no end."
        }
        return expiry.map { "Not active — expired \($0)." } ?? "Not active."
    }
}
