import PAIKit
import SwiftUI

/// A session's own supervisor, read-only — open from its actions menu. Offers to attach one when
/// none is watching yet, and reads (never edits) an existing one's configuration, state and
/// verdict history otherwise; editing an attached supervisor's own configuration belongs to the
/// scheduler's own configuration screen, not this menu.
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
        } else if let detail = store.detail {
            attachedView(store, detail)
        } else {
            attachOfferView(store)
        }
    }

    // MARK: - No supervisor yet

    private func attachOfferView(_ store: SupervisionStore) -> some View {
        List {
            Section {
                Text("Nothing is watching this session yet.")
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            Section("Model") {
                ForEach(CreateSessionStore.modelOptions, id: \.label) { option in
                    Button {
                        Task { await store.attach(model: option.id) }
                    } label: {
                        HStack {
                            Text(option.label)
                                .foregroundStyle(PaiPalette.Semantic.textPrimary)
                            Spacer()
                            if store.isBusy {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(store.isBusy)
                }
            }
            if let error = store.errorMessage {
                Section {
                    Text(error)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                }
            }
        }
    }

    // MARK: - An existing supervisor

    private func attachedView(_ store: SupervisionStore, _ detail: SupervisionDetail) -> some View {
        List {
            Section {
                LabeledContent("State") { Text(stateLabel(detail.state)) }
                if let model = detail.model {
                    LabeledContent("Model") { Text(model) }
                }
                if let memo = detail.memo, !memo.isEmpty {
                    LabeledContent("Memo") { Text(memo) }
                }
            }
            if let verdicts = detail.verdicts, !verdicts.isEmpty {
                Section("Verdicts") {
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
            }
            Section {
                Button(role: .destructive) {
                    confirmingDetach = true
                } label: {
                    if store.isBusy {
                        ProgressView()
                    } else {
                        Text("Detach")
                    }
                }
                .disabled(store.isBusy)
            } footer: {
                Text("The supervisor's own transcript and verdict history are kept even after detaching.")
            }
            if let error = store.errorMessage {
                Section {
                    Text(error)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                }
            }
        }
        .confirmationDialog("Detach the supervisor?", isPresented: $confirmingDetach, titleVisibility: .visible) {
            Button("Detach", role: .destructive) { Task { await store.detach() } }
            Button("Cancel", role: .cancel) {}
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
