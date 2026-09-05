import PAIKit
import SwiftUI

/// Every action the web's `SessionActionsMenu` offers, in one sheet — reached from the session
/// list row (long-press) and from the chat header ("…"), matching the web's own claim that a
/// session behaves the same however the menu was reached.
///
/// SwiftUI's `.sheet` already gives the bottom-sheet-on-phone shape the web builds by hand
/// (`isCompact` + a portalled `fixed inset-x-0 bottom-0` panel); a `NavigationStack` inside it is
/// what the web's `view`/`setView` state machine becomes natively, push-based rather than a
/// hand-rolled back button.
struct SessionActionsSheet: View {
    let sessionId: String

    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionListStore.self) private var sessionList
    @Environment(MeStore.self) private var me
    @Environment(ToastCenter.self) private var toasts

    @State private var actions: SessionActionsStore?
    @State private var path: [ActionsRoute] = []
    @State private var arcSpecTarget: ArcSpecResolution?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let actions {
                    RootActionsList(actions: actions, isOwner: me.isOwner, path: $path) {
                        actions.deleteNow()
                        // This is the one moment a deleted session's staged attachments can be
                        // told apart from one merely not yet loaded — `deleteSession` is the
                        // app's single delete entry point (`SessionListStore.deleteSession`'s own
                        // doc comment), so nothing else needs to guess at whether a session is
                        // truly gone. `set([], for:)` both clears the in-memory list and removes
                        // the disk mirror, the same as the composer's own send-clears-it path.
                        environment.connection?.staging.set([], for: sessionId)
                        dismiss()
                        // Leaves a dead transcript screen behind otherwise: the row is gone from
                        // the list the moment `deleteNow` runs, but nothing pops the screen that
                        // was *about* that row unless this sheet was reached from the list itself,
                        // where the path never held it to begin with — a no-op there.
                        environment.router.dismissSession(id: sessionId)
                        toasts.show("Session deleted")
                    } onClose: {
                        dismiss()
                        environment.router.dismissSession(id: sessionId)
                    } onCloseFailed: {
                        toasts.show(actions.errorMessage ?? "Could not close the session", kind: .error)
                    } onOpenSubagents: {
                        dismiss()
                        environment.router.push(.subagents(parentID: sessionId))
                    } onOpenSpec: {
                        Task {
                            // A single bound spec is already pushed by the time this returns
                            // `nil` — matching every other entry point's own "push before
                            // dismissing" rule (`CreateSessionView`'s doc comment on the same
                            // trap). Only the ambiguous/empty/failed cases need this sheet to
                            // stay open a moment longer, for the picker below.
                            if let resolution = await resolveArcSpec(
                                claudeSessionID: actions.session?.claudeSessionId,
                                api: environment.connection?.apiClient, router: environment.router)
                            {
                                arcSpecTarget = resolution
                            } else {
                                dismiss()
                            }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationDestination(for: ActionsRoute.self) { route in
                if let actions {
                    destination(for: route, actions: actions)
                }
            }
            .navigationTitle(actions?.session.map { SessionListDomain.sessionHeaderTitle(for: $0) } ?? "Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            guard actions == nil, let client = environment.connection?.apiClient else { return }
            actions = SessionActionsStore(sessionId: sessionId, sessionList: sessionList, api: client)
        }
        .presentationDetents([.medium, .large])
        // A picker chosen here also closes THIS sheet — the web's own menu closes itself before
        // routing to the spec (`SessionActionsMenu.tsx`'s `openArcForSession` call), and leaving
        // it open would strand it on top of wherever the push just landed. Built inline rather
        // than through the shared `arcSpecPicker(_:router:)` helper the list and transcript swipe
        // actions use, since only this entry point also needs to dismiss its own sheet.
        .sheet(item: $arcSpecTarget) { resolution in
            ArcSpecPickerSheet(resolution: resolution) { specUuid in
                environment.router.push(.arcSpec(specUuid: specUuid))
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func destination(for route: ActionsRoute, actions: SessionActionsStore) -> some View {
        switch route {
        case .rename:
            RenameActionView(actions: actions, toasts: toasts, onDone: { dismiss() })
        case .timeout:
            IdleTimeoutActionView(actions: actions, toasts: toasts)
        case .export:
            ExportActionView(actions: actions)
        case .supervision:
            SupervisionView(sessionId: sessionId)
        }
    }
}

private enum ActionsRoute: Hashable {
    case rename, timeout, export, supervision
}

// MARK: - Root list

private struct RootActionsList: View {
    @Environment(AppEnvironment.self) private var environment

    let actions: SessionActionsStore
    let isOwner: Bool
    @Binding var path: [ActionsRoute]
    let onDelete: () -> Void
    let onClose: () -> Void
    let onCloseFailed: () -> Void
    let onOpenSubagents: () -> Void
    let onOpenSpec: () -> Void

    @State private var copiedConversationId = false
    @State private var copiedLink = false
    @State private var confirmingDelete = false

    var body: some View {
        List {
            if let session = actions.session {
                if isOwner {
                    Button {
                        path.append(.rename)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                }

                // A subagent's own children, if any, are flattened into its top-level parent's
                // list — this view has nothing of its own to show for one.
                if session.kind != .subagent {
                    Button(action: onOpenSubagents) {
                        Label("Subagents", systemImage: "cpu")
                    }
                }

                // Unlike the web, which hides this until a fetch confirms a bound spec exists,
                // this always shows and resolves on tap — the same "just ask, then say so if
                // there is nothing" shape the list's own swipe action and the transcript's edge
                // swipe both already use for this exact question.
                Button(action: onOpenSpec) {
                    Label("Spec", systemImage: "shippingbox")
                }

                // Open, read-only, whether or not one is attached yet — `SupervisionView` itself
                // decides between an attach offer and a read-only view once it has asked.
                Button {
                    path.append(.supervision)
                } label: {
                    Label("Supervisor", systemImage: "eye")
                }

                if let url = SessionListDomain.claudeCodeUrl(cseId: session.cseId) {
                    Link(destination: url) {
                        Label("Open in Claude Code", systemImage: "arrow.up.forward.app")
                    }
                }

                if let conversationId = session.claudeSessionId {
                    Button {
                        UIPasteboard.general.string = conversationId
                        copiedConversationId = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copiedConversationId = false
                        }
                    } label: {
                        Label(
                            "Copy conversation id", systemImage: copiedConversationId ? "checkmark" : "doc.on.doc")
                    }
                }

                Button {
                    UIPasteboard.general.string = "\(environment.backendURL)/session/\(actions.sessionId)"
                    copiedLink = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedLink = false
                    }
                } label: {
                    Label("Copy link to this session", systemImage: copiedLink ? "checkmark" : "link")
                }

                Button {
                    path.append(.export)
                } label: {
                    Label("Export transcript…", systemImage: "square.and.arrow.down")
                }

                if isOwner {
                    Button {
                        path.append(.timeout)
                    } label: {
                        HStack {
                            Label("Close when idle…", systemImage: "timer")
                            Spacer()
                            Text(Self.formatIdleWindow(session.effectiveIdleTimeoutMinutes))
                                .font(PaiTypography.caption.font)
                                .foregroundStyle(PaiPalette.Semantic.textFaint)
                        }
                    }

                    if session.state != nil, session.state != .closed {
                        Button {
                            Task {
                                if await actions.close() {
                                    onClose()
                                } else {
                                    onCloseFailed()
                                }
                            }
                        } label: {
                            Label("Close session", systemImage: "power")
                        }
                    }

                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Delete session", systemImage: "trash")
                    }
                }
            } else {
                ProgressView()
            }
        }
        .accessibilityIdentifier("session-actions-list")
        // No undo past this point — the confirm step is the only safety net there is, matching
        // the web's `DeleteConfirmDialog` wording exactly.
        .confirmationDialog(
            "Delete session?", isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            if let session = actions.session {
                Text(
                    "\"\(SessionListDomain.sessionHeaderTitle(for: session))\" and everything derived from it — turns, summaries — will be deleted immediately and cannot be undone. Extracted memories are kept."
                )
            }
        }
    }

    private static func formatIdleWindow(_ minutes: Int?) -> String {
        guard let minutes else { return "" }
        if minutes == 0 { return "never" }
        if minutes % 60 == 0 { return "\(minutes / 60) h" }
        return "\(minutes) min"
    }
}

// MARK: - Rename

private struct RenameActionView: View {
    let actions: SessionActionsStore
    let toasts: ToastCenter
    let onDone: () -> Void

    @State private var text: String
    @State private var followsPhaseName: Bool
    @State private var isSaving = false

    init(actions: SessionActionsStore, toasts: ToastCenter, onDone: @escaping () -> Void) {
        self.actions = actions
        self.toasts = toasts
        self.onDone = onDone
        _text = State(initialValue: actions.session?.title ?? "")
        // Checked means unlocked (`!titleLocked`) — see `SessionActionsStore.setTitleLocked`'s
        // doc comment for why the checkbox is phrased this way.
        _followsPhaseName = State(initialValue: !(actions.session?.titleLocked ?? false))
    }

    var body: some View {
        Form {
            Section {
                TextField("Session name", text: $text)
                    .accessibilityIdentifier("session-rename-field")
            }
            Section {
                Toggle("Follow the phase name from the VM", isOn: $followsPhaseName)
            } footer: {
                Text("Until a name is chosen here, the session carries whatever the VM is calling the work.")
            }
        }
        .navigationTitle("Rename session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let renamed = await actions.rename(title: text)
        let lockChanged = await actions.setTitleLocked(!followsPhaseName)
        if renamed && lockChanged {
            onDone()
        } else {
            toasts.show(actions.errorMessage ?? "Rename failed", kind: .error)
        }
    }
}

// MARK: - Idle timeout

private struct IdleTimeoutActionView: View {
    let actions: SessionActionsStore
    let toasts: ToastCenter

    /// `nil` follows the deployment default and `0` never closes — the two values the API takes
    /// for those, so nothing here has to know what the default currently is.
    private static let choices: [(label: String, minutes: Int?)] = [
        ("Default", nil), ("1 hour", 60), ("3 hours", 180), ("12 hours", 720), ("24 hours", 1440),
        ("Never close", 0),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.choices, id: \.label) { choice in
                    Button {
                        Task {
                            if !(await actions.setIdleTimeout(minutes: choice.minutes)) {
                                toasts.show(actions.errorMessage ?? "Could not change the idle timeout", kind: .error)
                            }
                        }
                    } label: {
                        HStack {
                            Text(choice.label)
                                .foregroundStyle(PaiPalette.Semantic.textPrimary)
                            Spacer()
                            if choice.minutes == actions.session?.idleTimeoutMinutes {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(PaiPalette.green500)
                            }
                        }
                    }
                }
            } footer: {
                Text(
                    "The process is stopped after this long with nothing sent. The conversation is kept either way, and sending again resumes it."
                )
            }
        }
        .navigationTitle("Close when idle for")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Export

private struct ExportActionView: View {
    let actions: SessionActionsStore

    @State private var customDate = Date()
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var exportedFile: URL?

    var body: some View {
        List {
            Section {
                ForEach(Array(ExportPreset.allCases.enumerated()), id: \.offset) { _, preset in
                    Button {
                        Task { await export(since: preset.sinceIso()) }
                    } label: {
                        Text(preset.label)
                            .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    }
                    .disabled(isExporting)
                }
            }
            Section {
                DatePicker("Custom start time", selection: $customDate)
                    .datePickerStyle(.compact)
                Button("Export from this time") {
                    Task { await export(since: ISO8601DateFormatter().string(from: customDate)) }
                }
                .disabled(isExporting)
            }
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                }
            }
        }
        .navigationTitle("Export transcript")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isExporting { ProgressView() }
        }
        .sheet(item: Binding(get: { exportedFile.map(ShareItem.init) }, set: { exportedFile = $0?.url })) { item in
            ShareSheet(activityItems: [item.url])
        }
    }

    private func export(since: String?) async {
        isExporting = true
        errorMessage = nil
        defer { isExporting = false }
        guard let result = await actions.exportTranscript(since: since) else {
            errorMessage = actions.errorMessage ?? "Export failed"
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(result.filename)
        do {
            try result.data.write(to: url, options: .atomic)
            exportedFile = url
        } catch {
            errorMessage = "Could not save the export"
        }
    }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
