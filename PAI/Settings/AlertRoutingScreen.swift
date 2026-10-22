import PAIKit
import SwiftUI

/// The page behind Settings' "Alert routing" row: for each kind of alert, whether it reaches the
/// person (push and mail), the agent task, or both. The kinds come from the server.
struct AlertRoutingScreen: View {
    let routing: AlertRoutingStore

    var body: some View {
        Form {
            if let settings = routing.settings {
                taskSection(settings)
                kindsSection(settings)
            } else if let error = routing.errorMessage {
                Text(error)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            } else {
                ProgressView()
            }
            if routing.settings != nil, let error = routing.errorMessage {
                Text(error)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            }
        }
        .paiListBackground()
        .navigationTitle("Alert routing")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if routing.settings == nil { await routing.load() }
            await routing.loadTasks()
        }
    }

    private func taskSection(_ settings: AlertRoutingSettings) -> some View {
        Section {
            Picker("Agent task", selection: taskBinding(settings)) {
                Text("None").tag("")
                if let chosen = settings.agentTaskId, !routing.chosenTaskIsListed {
                    Text(settings.agentTaskName ?? chosen).tag(chosen)
                }
                ForEach(routing.tasks) { task in
                    Text(task.name).tag(task.id)
                }
            }
            .disabled(routing.isSaving)
            .accessibilityIdentifier("alert-routing-task")
            if let problem = routing.agentProblem {
                Text("Alerts routed to the agent reach you instead: \(problem).")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.warningText)
            }
        } footer: {
            Text("Who hears about each kind of alert: you (push and mail), the agent task, or both.")
        }
    }

    private func kindsSection(_ settings: AlertRoutingSettings) -> some View {
        Section("Kinds") {
            ForEach(settings.kinds) { kind in
                VStack(alignment: .leading, spacing: 6) {
                    Text(kind.label)
                    Picker(kind.label, selection: routeBinding(kind.id)) {
                        ForEach(options(current: routing.route(forKind: kind.id)), id: \.self) { route in
                            Text(route.label).tag(route)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(routing.isSaving)
                    if routing.route(forKind: kind.id) != .notify {
                        kindTaskPicker(kind)
                        if let problem = routing.problem(forKind: kind.id) {
                            Text("This kind reaches you instead: \(problem).")
                                .font(PaiTypography.caption.font)
                                .foregroundStyle(PaiPalette.Semantic.warningText)
                        }
                    }
                }
                .accessibilityIdentifier("alert-routing-kind-\(kind.id)")
            }
        }
    }

    private func kindTaskPicker(_ kind: AlertKindInfo) -> some View {
        Picker("Agent task for \(kind.label)", selection: kindTaskBinding(kind.id)) {
            Text("Default agent task").tag("")
            if let chosen = routing.task(forKind: kind.id), !routing.kindTaskIsListed(kind.id) {
                Text(chosen).tag(chosen)
            }
            ForEach(routing.tasks) { task in
                Text(task.name).tag(task.id)
            }
        }
        .font(PaiTypography.caption.font)
        .disabled(routing.isSaving)
        .accessibilityIdentifier("alert-routing-kind-task-\(kind.id)")
    }

    /// A route this build has never heard of gets a segment of its own so the picker never shows
    /// a selection that matches none of its options.
    private func options(current: AlertRoute) -> [AlertRoute] {
        if case .unrecognized = current { return AlertRoute.choices + [current] }
        return AlertRoute.choices
    }

    private func routeBinding(_ kindId: String) -> Binding<AlertRoute> {
        Binding(
            get: { routing.route(forKind: kindId) },
            set: { route in Task { await routing.setRoute(route, forKind: kindId) } }
        )
    }

    private func kindTaskBinding(_ kindId: String) -> Binding<String> {
        Binding(
            get: { routing.task(forKind: kindId) ?? "" },
            set: { id in Task { await routing.setTask(id: id.isEmpty ? nil : id, forKind: kindId) } }
        )
    }

    private func taskBinding(_ settings: AlertRoutingSettings) -> Binding<String> {
        Binding(
            get: { settings.agentTaskId ?? "" },
            set: { id in Task { await routing.setAgentTask(id: id.isEmpty ? nil : id) } }
        )
    }
}
