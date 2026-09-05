import PAIKit
import SwiftUI

/// One scheduled task's own form — create when `taskId` is `nil`, edit otherwise. Swift port of
/// `TaskEditor.tsx`. On a successful create this replaces itself with `.schedulerTask(id:
/// saved.id)` rather than mutating in place, the same "a new task id is a new screen" rule the
/// web expresses by keying its own `TaskEditor` on the task's id.
struct TaskEditorView: View {
    let taskId: String?

    @Environment(AppEnvironment.self) private var environment
    @State private var store: TaskEditorStore?
    @State private var hasReplacedRoute = false
    @State private var confirmingDelete = false
    @State private var testRunResult: SchedulerTestRunResult?

    var body: some View {
        Group {
            if let store {
                content(store)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task {
            guard store == nil, let client = environment.connection?.apiClient else { return }
            let newStore = TaskEditorStore(taskId: taskId, api: client, timezone: TimeZone.current.identifier)
            store = newStore
            await newStore.load()
        }
        .confirmationDialog("Delete this task?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    if await store?.delete() == true {
                        environment.router.pop()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var navigationTitle: String {
        if let name = store?.task?.name, !name.isEmpty { return name }
        return taskId == nil ? "New task" : "Task"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let store, let task = store.task {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if task.stopped {
                    Button("Clear stop") { Task { await store.clearStop() } }
                }
                Button(task.enabled ? "Disable" : "Enable") {
                    Task { await store.setEnabled(!task.enabled) }
                }
                Button {
                    Task { await store.runNow() }
                } label: {
                    Image(systemName: "play")
                }
                .disabled(task.stopped)
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ store: TaskEditorStore) -> some View {
        if store.isLoading {
            ProgressView()
        } else {
            Form {
                if let error = store.errorMessage {
                    Section {
                        Text(error).foregroundStyle(PaiPalette.Semantic.errorText)
                    }
                }
                if let task = store.task, task.stopped {
                    Section {
                        Label(
                            "Stopped\(task.stoppedReason.map { ": \($0)" } ?? "")",
                            systemImage: "exclamationmark.octagon.fill"
                        )
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                    }
                }

                Section("Name") {
                    TextField("Name", text: nameBinding(store))
                        .accessibilityIdentifier("scheduler-task-name")
                }

                environmentSection(store)

                Section("Prompt") {
                    TextEditor(text: promptBinding(store))
                        .frame(minHeight: 90)
                }

                Section {
                    if store.promptStaleOnEdit {
                        Label(
                            "This task reuses its conversation, which already launched — a change here applies only once that conversation is reset.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.warningText)
                        Button("Reset session to apply") { Task { await store.reset() } }
                            .font(PaiTypography.caption.font)
                    }
                    TextEditor(text: appendSystemPromptBinding(store))
                        .frame(minHeight: 60)
                } header: {
                    Text("Appended system prompt (optional)")
                }

                Section("Schedule") {
                    TextField("Cadence (5-field cron, blank = manual/webhook only)", text: cadenceBinding(store))
                        .font(PaiTypography.monoLabel.font)
                    TextField("Timezone", text: timezoneBinding(store))
                }

                if let task = store.task {
                    Section {
                        WebhookControlSection(store: store, environment: task.environment, hasWebhook: task.hasWebhook)
                    }
                }

                Section("Session policy") {
                    Picker("Session policy", selection: sessionPolicyBinding(store)) {
                        Text("Fresh conversation every fire").tag(TaskSessionPolicy.fresh)
                        Text("Resume the same conversation").tag(TaskSessionPolicy.reuse)
                        Text("Fire once, then clean up").tag(TaskSessionPolicy.oneShot)
                    }
                    .pickerStyle(.navigationLink)
                    Stepper(
                        "Quiet period: \(store.fields.quietPeriodMinutes) min",
                        value: quietPeriodBinding(store), in: 1...1440
                    )
                }

                Section("Model") {
                    modelPicker(store)
                }

                Section {
                    Toggle("Supervised", isOn: supervisionEnabledBinding(store))
                    if store.fields.supervisionEnabled {
                        supervisionModelPicker(store)
                    }
                }

                gateSection(store)

                Section {
                    Button {
                        Task { _ = await store.save() }
                    } label: {
                        HStack {
                            if store.isSaving { ProgressView() }
                            Text(store.isCreating ? "Create task" : "Save changes")
                        }
                    }
                    .disabled(store.isSaving || store.fields.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("scheduler-task-save")
                }

                if let taskId = store.taskId {
                    Section("Run history") {
                        RunHistorySection(taskId: taskId)
                    }
                }
            }
            // A brand-new task, once saved, is a different screen (a real id) rather than this
            // same store silently adopting one — matching the web's own `key`-based remount.
            // `pop()` then `push()` rather than a single "replace the top route" call, which
            // `Router` has no need for anywhere else: this is the one screen that becomes a
            // different route under itself, everywhere else navigates by pushing forward.
            .onChange(of: store.task?.id) { _, newID in
                guard taskId == nil, let newID, !hasReplacedRoute else { return }
                hasReplacedRoute = true
                environment.router.pop()
                environment.router.push(.schedulerTask(id: newID))
            }
        }
    }

    // MARK: - Environment

    @ViewBuilder
    private func environmentSection(_ store: TaskEditorStore) -> some View {
        Section("Environment") {
            Picker("Environment", selection: environmentBinding(store)) {
                Text("Default").tag("default")
                Text("Fast").tag("fast")
                Text("Web Search").tag("websearch")
                Text("Confined").tag("confined")
            }
            .pickerStyle(.navigationLink)

            switch store.fields.environment {
            case "default", "confined":
                HStack {
                    Text(store.fields.workingDir ?? "No directory selected")
                        .font(PaiTypography.monoLabel.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button("Browse") { showingDirectoryBrowser = true }
                }
            case "websearch":
                Text("(confined — no working directory)")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
            default:
                EmptyView()
            }
        }
        .sheet(isPresented: $showingDirectoryBrowser) {
            DirectoryBrowserView(agent: MachineStore.defaultMachineSlug, api: environment.connection?.apiClient) {
                path in
                store.fields.workingDir = path
            }
        }
    }

    @State private var showingDirectoryBrowser = false

    private func environmentBinding(_ store: TaskEditorStore) -> Binding<String> {
        Binding(
            get: { store.fields.environment },
            set: { newValue in
                store.fields.environment = newValue
                // Only "default" and "confined" let Freddy pick a directory — everything else
                // clears whatever was carried over from a previous choice rather than silently
                // keeping a stale value the new environment's own field never shows.
                if newValue != "default" && newValue != "confined" { store.fields.workingDir = nil }
            }
        )
    }

    // MARK: - Model

    /// A row of plain buttons rather than a native `Picker` — the same choice
    /// `CreateSessionView.modelPicker` makes, and for the same reason: a `Picker` bound to
    /// `String?` has to distinguish "Default" (`nil`) as a real, selectable tag, which is exactly
    /// the shape SwiftUI's optional-tag matching has a history of getting wrong.
    private func modelPicker(_ store: TaskEditorStore) -> some View {
        let disabled = store.fields.environment == "fast"
        return VStack(alignment: .leading, spacing: 4) {
            modelOptionRow(selected: store.fields.model, disabled: disabled) { store.fields.model = $0 }
            if disabled {
                Text("Fast sessions always run Sonnet.")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
        }
    }

    private func supervisionModelPicker(_ store: TaskEditorStore) -> some View {
        modelOptionRow(selected: store.fields.supervisionModel, disabled: false) {
            store.fields.supervisionModel = $0
        }
    }

    private func modelOptionRow(selected: String?, disabled: Bool, onSelect: @escaping (String?) -> Void)
        -> some View
    {
        HStack(spacing: 6) {
            ForEach(CreateSessionStore.modelOptions, id: \.label) { option in
                let isSelected = selected == option.id
                Button(option.label) { onSelect(option.id) }
                    .buttonStyle(.bordered)
                    .tint(isSelected ? PaiPalette.primary500 : PaiPalette.Semantic.textFaint)
                    .disabled(disabled)
            }
        }
    }

    // MARK: - Gate

    @ViewBuilder
    private func gateSection(_ store: TaskEditorStore) -> some View {
        Section("Gate script") {
            Toggle("This task has a gate script", isOn: hasGateBinding(store))
            if store.hasGate {
                Picker("Runtime", selection: gateRuntimeBinding(store)) {
                    Text("Bun").tag(TaskGateRuntime.bun)
                    Text("Python").tag(TaskGateRuntime.python)
                }
                Stepper(
                    "Timeout: \(store.fields.gateTimeoutSeconds)s", value: gateTimeoutBinding(store), in: 1...300)
                TextEditor(text: gateSourceBinding(store))
                    .font(PaiTypography.monoLabel.font)
                    .frame(minHeight: 120)
                Button {
                    Task { testRunResult = await store.testRunGate() }
                } label: {
                    HStack {
                        if store.isBusy { ProgressView() }
                        Text("Test run")
                    }
                }
                .disabled(store.isCreating || store.isBusy)
                if store.isCreating {
                    Text("Save the task first to test its gate.")
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textFaint)
                }
                if let result = testRunResult {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            result.proceed ? "Proceeds" : "Declines",
                            systemImage: result.proceed ? "checkmark.circle" : "xmark.circle"
                        )
                        .foregroundStyle(result.proceed ? PaiPalette.green500 : PaiPalette.Semantic.errorText)
                        if !result.stdout.isEmpty {
                            Text(result.stdout).font(PaiTypography.monoLabel.font)
                        }
                        if !result.stderr.isEmpty {
                            Text(result.stderr)
                                .font(PaiTypography.monoLabel.font)
                                .foregroundStyle(PaiPalette.Semantic.errorText)
                        }
                        if result.timedOut {
                            Text("Timed out").foregroundStyle(PaiPalette.Semantic.warningText)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Bindings

    private func nameBinding(_ store: TaskEditorStore) -> Binding<String> {
        Binding(get: { store.fields.name }, set: { store.fields.name = $0 })
    }
    private func promptBinding(_ store: TaskEditorStore) -> Binding<String> {
        Binding(get: { store.fields.prompt }, set: { store.fields.prompt = $0 })
    }
    private func appendSystemPromptBinding(_ store: TaskEditorStore) -> Binding<String> {
        Binding(
            get: { store.fields.appendSystemPrompt ?? "" },
            set: { store.fields.appendSystemPrompt = $0.isEmpty ? nil : $0 })
    }
    private func cadenceBinding(_ store: TaskEditorStore) -> Binding<String> {
        Binding(get: { store.fields.cadence ?? "" }, set: { store.fields.cadence = $0.isEmpty ? nil : $0 })
    }
    private func timezoneBinding(_ store: TaskEditorStore) -> Binding<String> {
        Binding(get: { store.fields.timezone }, set: { store.fields.timezone = $0 })
    }
    private func sessionPolicyBinding(_ store: TaskEditorStore) -> Binding<TaskSessionPolicy> {
        Binding(get: { store.fields.sessionPolicy }, set: { store.fields.sessionPolicy = $0 })
    }
    private func quietPeriodBinding(_ store: TaskEditorStore) -> Binding<Int> {
        Binding(get: { store.fields.quietPeriodMinutes }, set: { store.fields.quietPeriodMinutes = $0 })
    }
    private func supervisionEnabledBinding(_ store: TaskEditorStore) -> Binding<Bool> {
        Binding(get: { store.fields.supervisionEnabled }, set: { store.fields.supervisionEnabled = $0 })
    }
    private func hasGateBinding(_ store: TaskEditorStore) -> Binding<Bool> {
        Binding(get: { store.hasGate }, set: { store.setHasGate($0) })
    }
    private func gateRuntimeBinding(_ store: TaskEditorStore) -> Binding<TaskGateRuntime> {
        Binding(get: { store.fields.gateRuntime ?? .bun }, set: { store.fields.gateRuntime = $0 })
    }
    private func gateTimeoutBinding(_ store: TaskEditorStore) -> Binding<Int> {
        Binding(get: { store.fields.gateTimeoutSeconds }, set: { store.fields.gateTimeoutSeconds = $0 })
    }
    private func gateSourceBinding(_ store: TaskEditorStore) -> Binding<String> {
        Binding(get: { store.fields.gateSource ?? "" }, set: { store.fields.gateSource = $0 })
    }
}

/// Mint or revoke a task's webhook token — a session-menu-scale control, not a full port of the
/// web's own copy: the "shown once" token and the scoped-environment refusal both carry over.
private struct WebhookControlSection: View {
    let store: TaskEditorStore
    let environment: String
    let hasWebhook: Bool

    private var isScoped: Bool { environment == "websearch" }

    var body: some View {
        if !isScoped {
            Text(
                "Only the web search environment accepts a webhook trigger — an untrusted external payload needs a kernel-confined environment that can also report a result."
            )
            .font(PaiTypography.caption.font)
            .foregroundStyle(PaiPalette.Semantic.textFaint)
        } else if let token = store.mintedWebhookToken {
            VStack(alignment: .leading, spacing: 4) {
                Text("Shown once — copy it now, it cannot be shown again:")
                    .font(PaiTypography.captionEmphasized.font)
                    .foregroundStyle(PaiPalette.Semantic.warningText)
                HStack {
                    Text(token).font(PaiTypography.monoLabel.font).lineLimit(1).truncationMode(.middle)
                    Button {
                        UIPasteboard.general.string = token
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
                Button("Dismiss") { store.dismissMintedWebhookToken() }
                    .font(PaiTypography.caption.font)
            }
        } else if hasWebhook {
            HStack {
                Text("Configured").font(PaiTypography.caption.font).foregroundStyle(PaiPalette.Semantic.textMuted)
                Spacer()
                Button("Revoke") { Task { await store.revokeWebhook() } }
            }
        } else {
            Button {
                Task { await store.createWebhook() }
            } label: {
                HStack {
                    if store.isBusy { ProgressView() }
                    Text("Generate webhook")
                }
            }
            .disabled(store.isBusy)
        }
    }
}

/// A task's fire history, newest first — paged, loading more as the reader nears the end.
private struct RunHistorySection: View {
    let taskId: String

    @Environment(AppEnvironment.self) private var environment
    @State private var store: RunHistoryStore?

    var body: some View {
        Group {
            if let store {
                ForEach(store.runs) { run in
                    RunRow(run: run)
                        .onAppear {
                            guard store.hasMore, run.id == store.runs.last?.id else { return }
                            Task { await store.loadMore() }
                        }
                }
                if store.runs.isEmpty && !store.isLoading {
                    Text("This task has not fired yet.")
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                }
                if store.isLoading {
                    ProgressView()
                }
                if let error = store.errorMessage {
                    Text(error).font(PaiTypography.caption.font).foregroundStyle(PaiPalette.Semantic.errorText)
                }
            } else {
                ProgressView()
            }
        }
        .task {
            guard store == nil, let client = environment.connection?.apiClient else { return }
            let newStore = RunHistoryStore(taskId: taskId, api: client)
            store = newStore
            await newStore.loadMore()
        }
    }
}

private struct RunRow: View {
    let run: TaskRun

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(dispositionLabel)
                    .font(PaiTypography.captionEmphasized.font)
                    .foregroundStyle(dispositionColor)
                Text(triggerLabel)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
                Spacer()
                Text(formattedStartedAt)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
            }
            if let reason = run.reason, !reason.isEmpty {
                Text(reason).font(PaiTypography.caption.font).foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            if let sessionId = run.sessionId {
                Button("Open session") {
                    environment.router.push(.session(id: sessionId))
                }
                .font(PaiTypography.caption.font)
            }
        }
        .padding(.vertical, 2)
    }

    private var formattedStartedAt: String {
        Date(timeIntervalSince1970: Double(run.startedAtMs) / 1000)
            .formatted(date: .abbreviated, time: .shortened)
    }

    private var dispositionLabel: String {
        switch run.disposition {
        case .fired: return "fired"
        case .declined: return "declined"
        case .skipped: return "skipped"
        case .deferred: return "deferred"
        case .refused: return "refused"
        case .error: return "error"
        case .unrecognized(let raw): return raw
        }
    }

    private var triggerLabel: String {
        switch run.trigger {
        case .schedule: return "SCHEDULE"
        case .webhook: return "WEBHOOK"
        case .manual: return "MANUAL"
        case .unrecognized(let raw): return raw.uppercased()
        }
    }

    private var dispositionColor: Color {
        switch run.disposition {
        case .fired: return PaiPalette.Semantic.accentText
        case .declined, .skipped: return PaiPalette.Semantic.textMuted
        case .deferred: return PaiPalette.Semantic.warningText
        case .refused, .error: return PaiPalette.Semantic.errorText
        case .unrecognized: return PaiPalette.Semantic.textMuted
        }
    }
}
