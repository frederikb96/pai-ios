import PAIKit
import SwiftUI

/// The "New Session" flow, presented as a sheet from the session list.
///
/// A sheet rather than a pushed screen: this is a self-contained compose action with no reason
/// to leave a trail on the navigation stack, the same choice iOS makes for Mail's and Messages'
/// own "new" flows.
///
/// `CreateSessionStore` is built fresh for each presentation rather than held in the shared
/// environment — the store's own doc comment is explicit that the machine choice must never be
/// remembered between visits, and a store scoped to this view's lifetime is what makes that true
/// for free rather than needing an explicit reset call every time the sheet reopens.
struct CreateSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionListStore.self) private var sessionList
    @Environment(MachineStore.self) private var machines

    @State private var createSession: CreateSessionStore?
    @State private var messageText = ""
    @State private var isPresentingDirectoryBrowser = false
    @State private var errorMessage: String?
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("New Session")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .task {
            guard createSession == nil, let client = environment.connection?.apiClient else { return }
            let store = CreateSessionStore(machines: machines, api: client)
            createSession = store
            // Freshest possible online/offline picture at the moment stakes are highest: a
            // session about to launch on whichever machine turns out to be reachable.
            await machines.refresh()
            await store.start()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let createSession {
            Form {
                if MachineStore.hasMultipleAgents(machines.launchableMachines) {
                    Section("Machine") {
                        machinePicker(createSession)
                    }
                } else if machines.loaded && machines.launchableMachines.isEmpty {
                    // The web has no equivalent warning — sending to an offline VM silently
                    // creates a row that queues. Worth surfacing rather than porting the gap.
                    Section {
                        Label("No machine is online right now.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(PaiPalette.Semantic.warningText)
                    }
                }

                if !createSession.availableSessionTypes.isEmpty {
                    Section("Session Type") {
                        sessionTypePicker(createSession)
                        if let dir = createSession.workingDir {
                            HStack {
                                Text(dir)
                                    .font(PaiTypography.monoLabel.font)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Spacer()
                                Button("Change") { isPresentingDirectoryBrowser = true }
                                    .buttonStyle(.borderless)
                                Button("Clear") { createSession.selectWorkingDir(nil) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                Section("Message") {
                    TextField("Message Claude…", text: $messageText, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($isComposerFocused)
                        .accessibilityIdentifier("new-session-message")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(PaiPalette.Semantic.errorText)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                sendBar(createSession)
            }
            .sheet(isPresented: $isPresentingDirectoryBrowser) {
                DirectoryBrowserView(agent: createSession.selectedMachine, api: environment.connection?.apiClient) {
                    path in
                    createSession.selectWorkingDir(path)
                }
            }
        } else {
            ProgressView()
        }
    }

    // MARK: - Machine picker

    /// Only appears when there is a real choice — offline machines are absent, not disabled, the
    /// same rule the web's `AgentPicker` uses: a greyed control implies "maybe later," and there
    /// is nothing maybe-later about a machine that is not there right now.
    private func machinePicker(_ createSession: CreateSessionStore) -> some View {
        HStack(spacing: 8) {
            ForEach(machines.launchableMachines) { machine in
                let isSelected = createSession.selectedMachine == machine.slug
                Button {
                    createSession.selectMachine(machine.slug)
                    isComposerFocused = true
                } label: {
                    Text(machine.displayName)
                        .font(PaiTypography.bodyEmphasized.font)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            isSelected ? PaiPalette.Semantic.accentBackground : PaiPalette.Semantic.raisedSurface,
                            in: Capsule()
                        )
                        .foregroundStyle(
                            isSelected ? PaiPalette.Semantic.accentText : PaiPalette.Semantic.textPrimary
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .accessibilityIdentifier("machine-picker-\(machine.slug)")
            }
            Spacer()
        }
    }

    // MARK: - Session type picker

    private func sessionTypePicker(_ createSession: CreateSessionStore) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
            ForEach(createSession.availableSessionTypes) { type in
                SessionTypeCard(type: type, isSelected: createSession.selectedSessionTypeId == type.id) {
                    createSession.selectSessionType(type.id)
                    isComposerFocused = true
                }
                .accessibilityIdentifier("session-type-\(type.id)")
            }
            SessionTypeCard(
                type: SessionType(id: "custom", name: "Custom", icon: "📁"),
                isSelected: createSession.selectedSessionTypeId == "custom"
            ) {
                isPresentingDirectoryBrowser = true
            }
            .accessibilityIdentifier("session-type-custom")
        }
        .padding(.vertical, 4)
    }

    // MARK: - Send

    private func sendBar(_ createSession: CreateSessionStore) -> some View {
        HStack {
            Spacer()
            Button {
                send(createSession)
            } label: {
                if createSession.isCreating {
                    ProgressView()
                        .frame(width: 30, height: 30)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
            }
            .disabled(!canSend(createSession))
            .accessibilityIdentifier("create-session-send")
        }
        .padding()
        .background(.bar)
    }

    private func canSend(_ createSession: CreateSessionStore) -> Bool {
        !createSession.isCreating && !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send(_ createSession: CreateSessionStore) {
        let text = messageText
        Task {
            errorMessage = nil
            switch await createSession.create(message: text) {
            case .created(let session):
                sessionList.prependOptimisticSession(session)
                // Push before dismissing. A push onto the stack behind a sheet that is in the
                // middle of dismissing is dropped often enough to be a known iOS trap, and the
                // failure is silent: the session is created and the user stays on the list,
                // looking at a row they have to tap again.
                environment.router.push(.session(id: session.id))
                dismiss()
            case .failed(let message):
                // The draft is kept — text stays exactly where it was, matching the web:
                // a failure here should never cost what was already typed.
                errorMessage = message
            }
        }
    }
}

/// One session-type or "Custom" pill, presented as an icon card — the phone-friendly shape
/// Android already uses for this picker (`SessionTypeCard`), kept for its presentation only; the
/// selection and preselection rules underneath are the web's, verbatim.
private struct SessionTypeCard: View {
    let type: SessionType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(type.icon)
                    .font(.system(size: 28))
                Text(type.name)
                    .font(PaiTypography.captionEmphasized.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .padding(8)
            .background(
                isSelected ? PaiPalette.Semantic.accentBackground : PaiPalette.Semantic.raisedSurface,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? PaiPalette.primary500 : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
