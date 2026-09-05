import PAIKit
import SwiftUI

/// PAI's own scheduler: every task, newest first, with a way to create one. Swift port of the
/// list half of `SchedulerApp.tsx` — the create/edit form itself is `TaskEditorView`, its own
/// pushed page under `.schedulerTask(id:)`.
struct SchedulerListView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var store: SchedulerListStore?

    var body: some View {
        Group {
            if let store {
                content(store)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Scheduler")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    environment.router.push(.schedulerTask(id: nil))
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("new-scheduled-task")
            }
        }
        .task {
            guard store == nil, let client = environment.connection?.apiClient else { return }
            let newStore = SchedulerListStore(api: client)
            store = newStore
            await newStore.load()
        }
    }

    @ViewBuilder
    private func content(_ store: SchedulerListStore) -> some View {
        if store.isLoading && store.tasks.isEmpty {
            ProgressView()
        } else if let error = store.errorMessage, store.tasks.isEmpty {
            VStack(spacing: 8) {
                Text(error)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await store.load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        } else if store.tasks.isEmpty {
            VStack(spacing: 4) {
                Text("No scheduled tasks yet.")
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                Text("A task pairs a schedule with an optional script that decides whether to actually run.")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        } else {
            List(store.tasks) { task in
                Button {
                    environment.router.push(.schedulerTask(id: task.id))
                } label: {
                    SchedulerTaskRow(task: task)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .refreshable { await store.load() }
        }
    }
}

private struct SchedulerTaskRow: View {
    let task: ScheduledTask

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(task.name)
                    .font(PaiTypography.bodyEmphasized.font)
                    .foregroundStyle(task.enabled ? PaiPalette.Semantic.textPrimary : PaiPalette.Semantic.textFaint)
                    .lineLimit(1)
                if SchedulerTaskDisplay.isStale(task, nowMs: Int(Date().timeIntervalSince1970 * 1000)) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(PaiPalette.Semantic.warningText)
                        .accessibilityLabel("No successful run in a while")
                }
                Spacer()
                statusPill
            }
            HStack(spacing: 6) {
                Text(task.environment)
                Text("·")
                Text(task.cadence ?? "on demand")
                if task.hasGate {
                    Image(systemName: "arrow.triangle.branch")
                }
                if !task.enabled {
                    Spacer()
                    Text("disabled")
                }
            }
            .font(PaiTypography.caption.font)
            .foregroundStyle(PaiPalette.Semantic.textMuted)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("scheduler-task-\(task.id)")
    }

    private var statusPill: some View {
        let (label, color): (String, Color) = {
            switch SchedulerTaskDisplay.lastRunStatus(task) {
            case .never: return ("never fired", PaiPalette.Semantic.textFaint)
            case .ok: return ("ok", PaiPalette.green500)
            case .attention: return ("attention", PaiPalette.Semantic.warningText)
            case .stopped: return ("stopped", PaiPalette.Semantic.errorText)
            }
        }()
        return Text(label)
            .font(PaiTypography.captionEmphasized.font)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}
