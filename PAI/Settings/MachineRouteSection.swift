import PAIKit
import SwiftUI

/// Which controller drives each machine's *next* launch or resume — this machine's own local
/// stand-in, or Anthropic's Remote Control. One row per machine rather than one global switch:
/// the two carry different stakes (the laptop holds customer repositories), and each machine
/// already reports its own capabilities independently.
///
/// A session already running is unaffected either way — this never reaches into one already in
/// flight, only what starts next. Nothing here is optimistic: a row shows what the agent reports
/// is in force once the switch resolves, not what was tapped.
struct MachineRouteSection: View {
    let machines: MachineStore

    @State private var pendingSlug: String?
    @State private var errorBySlug: [String: String] = [:]

    var body: some View {
        if !machines.allMachines.isEmpty {
            Section {
                ForEach(machines.allMachines) { machine in
                    row(for: machine)
                }
            } header: {
                Text("Machines")
            } footer: {
                Text(
                    "A session already running keeps whichever route it started on — this only "
                        + "decides what the next one launches with.")
            }
        }
    }

    @ViewBuilder
    private func row(for machine: Machine) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(machine.displayName, selection: routeBinding(for: machine)) {
                Text("Local").tag(RcRoute.local)
                Text("Anthropic").tag(RcRoute.anthropic)
            }
            .pickerStyle(.segmented)
            .disabled(pendingSlug == machine.slug)
            .accessibilityIdentifier("rc-route-\(machine.slug)")

            if !machine.capabilities.rcLocal && machine.capabilities.rcRoute != .local {
                Text("Local is not usable on this machine right now.")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
            }
            if let error = errorBySlug[machine.slug] {
                Text(error)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            }
        }
    }

    private func routeBinding(for machine: Machine) -> Binding<RcRoute> {
        Binding(
            get: { machine.capabilities.rcRoute },
            set: { newRoute in
                guard newRoute != machine.capabilities.rcRoute else { return }
                errorBySlug[machine.slug] = nil
                // The segmented control has no per-segment disabled state, so a tap on Local on
                // a machine that cannot run it is caught here rather than left to the request.
                guard newRoute != .local || machine.capabilities.rcLocal else {
                    errorBySlug[machine.slug] = "Local is not usable on this machine right now."
                    return
                }
                let slug = machine.slug
                pendingSlug = slug
                Task {
                    do {
                        try await machines.setRcRoute(slug: slug, route: newRoute)
                    } catch {
                        errorBySlug[slug] = errorMessage(error)
                    }
                    pendingSlug = nil
                }
            }
        )
    }

    private func errorMessage(_ error: Error) -> String {
        (error as? PaiError)?.userMessage ?? "Could not switch"
    }
}
