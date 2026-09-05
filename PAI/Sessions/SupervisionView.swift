import PAIKit
import SwiftUI

/// A session's own supervisor — open from its actions menu. Offers to attach one (sharing the
/// same controls the scheduler task editor pre-fills a fresh `Supervision` from) when nothing is
/// watching yet, or shows an existing one's state, configuration summary and verdict history,
/// with a link to its own conversation and a two-step detach. Swift port of the web's
/// `SupervisorPanel`.
///
/// Read-only once attached: this view never edits a LIVE supervision's own configuration — that
/// stays the scheduler's own configuration screen's job. Re-attaching after a detach is offered
/// again here, pre-filled from the previous configuration, since the backend allows it and
/// refuses only while one is genuinely active.
struct SupervisionView: View {
    let sessionId: String

    @Environment(AppEnvironment.self) private var environment
    @State private var store: SupervisionStore?
    @State private var confirmingDetach = false

    var body: some View {
        Group {
            if let store {
                content(store)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Supervisor")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard store == nil, let client = environment.connection?.apiClient else { return }
            let newStore = SupervisionStore(sessionId: sessionId, api: client)
            store = newStore
            await newStore.load()
        }
    }

    @ViewBuilder
    private func content(_ store: SupervisionStore) -> some View {
        if store.isLoading {
            ProgressView()
        } else if store.needsAttach {
            attachOfferView(store)
        } else if let detail = store.detail {
            attachedView(store, detail)
        }
    }

    // MARK: - Attach (or re-attach)

    private func attachOfferView(_ store: SupervisionStore) -> some View {
        List {
            Section {
                Text(
                    store.detail != nil
                        ? "The previous supervisor was detached. Attaching a new one starts fresh — its own conversation and verdict history are separate from the one before."
                        : "No supervisor attached. It watches this conversation as it runs and can stop it if something goes wrong — configure it the same way a scheduled task does."
                )
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            }

            Section("Model") {
                ForEach(CreateSessionStore.modelOptions, id: \.label) { option in
                    let isSelected = store.config.model == option.id
                    Button {
                        store.config.model = option.id
                    } label: {
                        HStack {
                            Text(option.label)
                                .foregroundStyle(PaiPalette.Semantic.textPrimary)
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Section {
                TextEditor(text: appendPromptBinding(store))
                    .frame(minHeight: 60)
            } header: {
                Text("Appended prompt (optional — default if left blank)")
            }

            Section("Compaction and flushing") {
                LabeledContent("Compaction threshold (tokens)") {
                    TextField("default", text: intFieldBinding(store, \.compactionThresholdTokens))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Flush interval (seconds)") {
                    TextField("default", text: intFieldBinding(store, \.chunkIntervalSeconds))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Flush threshold (tokens)") {
                    TextField("default", text: intFieldBinding(store, \.chunkTokenThreshold))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
            }

            if let error = store.errorMessage {
                Section {
                    Text(error)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                }
            }

            Section {
                Button {
                    Task { await store.attach() }
                } label: {
                    HStack {
                        if store.isBusy { ProgressView() }
                        Text("Attach supervisor")
                    }
                }
                .disabled(store.isBusy)
                .accessibilityIdentifier("supervisor-attach")
            }
        }
    }

    /// `SupervisionConfigFields`'s numeric fields are all `Int?`, with `nil` meaning "the
    /// module's own default" — never rendered as a placeholder value. A blank box round-trips to
    /// `nil` rather than `0`, matching that.
    private func intFieldBinding(_ store: SupervisionStore, _ keyPath: WritableKeyPath<SupervisionConfigFields, Int?>)
        -> Binding<String>
    {
        Binding(
            get: { store.config[keyPath: keyPath].map(String.init) ?? "" },
            set: { store.config[keyPath: keyPath] = Int($0) }
        )
    }

    private func appendPromptBinding(_ store: SupervisionStore) -> Binding<String> {
        Binding(
            get: { store.config.appendPrompt ?? "" },
            set: { store.config.appendPrompt = $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: - An existing, active supervisor

    private func attachedView(_ store: SupervisionStore, _ detail: SupervisionDetail) -> some View {
        List {
            Section {
                LabeledContent("State") { Text(stateLabel(detail.state)) }
                LabeledContent("Model") { Text(detail.model ?? "default") }
                LabeledContent("Compaction threshold") {
                    Text(detail.compactionThresholdTokens.map(String.init) ?? "default")
                }
                LabeledContent("Flush interval") {
                    Text(detail.chunkIntervalSeconds.map(String.init) ?? "default")
                }
                LabeledContent("Flush threshold") {
                    Text(detail.chunkTokenThreshold.map(String.init) ?? "default")
                }
            }

            Section {
                if let supervisorSessionId = detail.supervisorSessionId {
                    Button("Open supervisor's conversation (read-only)") {
                        environment.router.push(.session(id: supervisorSessionId))
                    }
                } else {
                    Text(
                        "The supervisor has not flushed anything yet — its own conversation starts on the first chunk there is something to watch."
                    )
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
                }
            }

            Section("Verdicts") {
                if let verdicts = detail.verdicts {
                    if verdicts.isEmpty {
                        Text("Nothing recorded yet.")
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.textFaint)
                    } else {
                        ForEach(verdicts) { verdict in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(verdictLabel(verdict.verdict))
                                        .font(PaiTypography.bodyEmphasized.font)
                                        .foregroundStyle(verdictColor(verdict.verdict))
                                    Spacer()
                                }
                                if let reason = verdict.reason, !reason.isEmpty {
                                    Text(reason)
                                        .font(PaiTypography.caption.font)
                                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                                }
                            }
                        }
                    }
                } else {
                    ProgressView()
                }
            }

            if let error = store.errorMessage {
                Section {
                    Text(error)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                }
            }

            Section {
                if confirmingDetach {
                    HStack {
                        Button("Cancel") { confirmingDetach = false }
                        Spacer()
                        Button(role: .destructive) {
                            Task { await store.detach() }
                        } label: {
                            HStack {
                                if store.isBusy { ProgressView() }
                                Text("Confirm detach")
                            }
                        }
                        .disabled(store.isBusy)
                    }
                } else {
                    Button(role: .destructive) {
                        confirmingDetach = true
                    } label: {
                        Text("Detach")
                    }
                    .accessibilityIdentifier("supervisor-detach")
                }
            } footer: {
                Text("The supervisor's own transcript and verdict history are kept even after detaching.")
            }
        }
    }

    private func stateLabel(_ state: SupervisionState) -> String {
        switch state {
        case .active: return "Active"
        case .degraded: return "Degraded"
        case .stopped: return "Stopped"
        case .ended: return "Ended"
        case .unrecognized(let raw): return raw
        }
    }

    private func verdictLabel(_ verdict: SupervisionVerdictValue) -> String {
        switch verdict {
        case .ok: return "OK"
        case .warning: return "Warning"
        case .stop: return "Stop"
        case .invalid: return "Invalid"
        case .unrecognized(let raw): return raw
        }
    }

    private func verdictColor(_ verdict: SupervisionVerdictValue) -> Color {
        switch verdict {
        case .ok: return PaiPalette.green500
        case .warning: return PaiPalette.Semantic.warningText
        case .stop, .invalid: return PaiPalette.Semantic.errorText
        case .unrecognized: return PaiPalette.Semantic.textMuted
        }
    }
}
