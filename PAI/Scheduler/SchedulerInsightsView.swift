import PAIKit
import SwiftUI

/// The scheduler's KPI page: last-week totals over finished scheduled runs and the tasks that
/// cost the most. Swift port of `InsightsPage.tsx`.
struct SchedulerInsightsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var store: SchedulerInsightsStore?

    var body: some View {
        Group {
            if let store {
                content(store)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard store == nil, let client = environment.connection?.apiClient else { return }
            let newStore = SchedulerInsightsStore(api: client)
            store = newStore
            await newStore.load()
        }
    }

    @ViewBuilder
    private func content(_ store: SchedulerInsightsStore) -> some View {
        if let insights = store.insights {
            List {
                Section("Last \(insights.days) days") {
                    kpi("Runs", String(insights.totals.runs))
                    kpi("Absolute tokens", SchedulerRunDisplay.formatTokens(insights.totals.tokensAbsolute))
                    kpi("Relative tokens", SchedulerRunDisplay.formatTokens(insights.totals.tokensRelative))
                    kpi(
                        "Run time",
                        SchedulerRunDisplay.formatDuration(ms: Int(insights.totals.runSeconds * 1000)))
                    kpi("Notified you", String(insights.totals.notified))
                }
                Section("Most expensive tasks") {
                    if insights.tasks.isEmpty {
                        Text("No finished runs in this window.")
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.textMuted)
                    }
                    ForEach(insights.tasks) { task in
                        Button {
                            environment.router.push(.schedulerTask(id: task.taskId))
                        } label: {
                            taskRow(task)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await store.load() }
        } else if let error = store.errorMessage {
            VStack(spacing: 8) {
                Text(error)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await store.load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        } else {
            ProgressView()
        }
    }

    private func kpi(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(PaiPalette.Semantic.textMuted)
            Spacer()
            Text(value).font(PaiTypography.bodyEmphasized.font).monospacedDigit()
        }
    }

    private func taskRow(_ task: SchedulerInsightsTask) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(task.name.isEmpty ? task.taskId : task.name)
                .font(PaiTypography.bodyEmphasized.font)
                .foregroundStyle(PaiPalette.Semantic.textPrimary)
                .lineLimit(1)
            let relative = SchedulerRunDisplay.formatTokens(task.tokensRelative)
            let absolute = SchedulerRunDisplay.formatTokens(task.tokensAbsolute)
            let runTime = SchedulerRunDisplay.formatDuration(ms: Int(task.runSeconds * 1000))
            Text("\(task.runs) runs · \(relative) relative · \(absolute) absolute · \(runTime)")
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
        }
        .contentShape(Rectangle())
    }
}
