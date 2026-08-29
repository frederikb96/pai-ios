import Foundation
import Observation

/// The narrow slice of `PaiApiClient` this file needs — see `/subagents`' guidance on declaring a
/// protocol per consumer rather than mirroring the whole client. `PaiApiClient` already conforms
/// structurally; the conformance is declared here, next to the protocol it satisfies.
public protocol MachineDirectoryApiClient: Sendable {
    func getMachines() async throws -> [Machine]
}

extension PaiApiClient: MachineDirectoryApiClient {}

/// Swift port of `pai-cloud/web/src/stores/agents.ts`. One store, shared by the session list's
/// machine chips and the New Session screen's machine picker — the two read it differently
/// (`allMachines` keeps offline machines for filtering *what to look at*; `launchableMachines`
/// drops them, because there is nothing to launch on a machine that is not there) but neither
/// owns a second poll of the same endpoint.
@MainActor
@Observable
public final class MachineStore {
    /// The VM's fixed slug (`config.VM_AGENT_SLUG` on the backend) — every session before
    /// multi-agent existed was one, so it is the default a new session launches on and the
    /// fallback for a session row with no `agent` field at all.
    public static let defaultMachineSlug = "vm"

    /// Every machine ever seen, most of which stay around after going offline.
    public private(set) var machines: [Machine] = []
    public private(set) var loaded = false

    private let api: MachineDirectoryApiClient

    public init(api: MachineDirectoryApiClient) {
        self.api = api
    }

    /// A stale list beats none — a poll tick that fails leaves `machines` exactly as it was, the
    /// same trade-off `fetchAgents` makes on the web.
    public func refresh() async {
        guard let fetched = try? await api.getMachines() else { return }
        machines = fetched
        loaded = true
    }

    /// The pill row — chips or the launch picker alike — only earns its place once there is a
    /// choice to make.
    public static func hasMultipleAgents(_ machines: [Machine]) -> Bool {
        machines.count > 1
    }

    /// What the session list's machine chips iterate — every machine ever seen. Offline ones stay
    /// selectable there: filtering what to look at is not choosing where to launch, and an
    /// offline laptop session is exactly what a chip is for finding.
    public var allMachines: [Machine] { machines }

    /// What the New Session screen's machine picker iterates. Absent, not disabled, for an
    /// offline machine — a greyed control implies "maybe later," and there is nothing maybe-later
    /// about a machine that is not there right now.
    public var launchableMachines: [Machine] { machines.filter(\.online) }
}
