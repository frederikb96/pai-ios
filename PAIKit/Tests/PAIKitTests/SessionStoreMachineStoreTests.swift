import XCTest
@testable import PAIKit

/// `MachineStore` is shared by the session list's chips (which want every machine, offline
/// included) and the New Session picker (which wants only what can actually be launched on) — the
/// two-list split is the thing a refactor could silently collapse into one.
@MainActor
final class SessionStoreMachineStoreTests: XCTestCase {

    private func makeMachine(slug: String, online: Bool) -> Machine {
        Machine(
            slug: slug, displayName: slug, online: online, lastSeenAt: nil, ingestEnabled: true,
            capabilities: .init(fastSessions: true, reboot: true, shell: true, rcLocal: true, rcRoute: .anthropic),
            sessionTypes: []
        )
    }

    func testAllMachinesKeepsOfflineOnesForTheFilterChips() async {
        let api = FakeMachineDirectoryApi()
        await api.setResult(
            .success([makeMachine(slug: "vm", online: true), makeMachine(slug: "laptop", online: false)]))
        let store = MachineStore(api: api)
        await store.refresh()

        XCTAssertEqual(store.allMachines.map(\.slug), ["vm", "laptop"])
    }

    func testLaunchableMachinesDropsOfflineOnesForTheNewSessionPicker() async {
        let api = FakeMachineDirectoryApi()
        await api.setResult(
            .success([makeMachine(slug: "vm", online: true), makeMachine(slug: "laptop", online: false)]))
        let store = MachineStore(api: api)
        await store.refresh()

        XCTAssertEqual(store.launchableMachines.map(\.slug), ["vm"])
    }

    func testHasMultipleAgentsRequiresMoreThanOne() {
        XCTAssertFalse(MachineStore.hasMultipleAgents([makeMachine(slug: "vm", online: true)]))
        XCTAssertTrue(
            MachineStore.hasMultipleAgents([
                makeMachine(slug: "vm", online: true), makeMachine(slug: "laptop", online: true),
            ])
        )
        XCTAssertFalse(MachineStore.hasMultipleAgents([]))
    }

    /// A stale list beats none — a failed refresh must not wipe out what was already loaded.
    func testFailedRefreshKeepsThePreviousMachineList() async {
        let api = FakeMachineDirectoryApi()
        await api.setResult(.success([makeMachine(slug: "vm", online: true)]))
        let store = MachineStore(api: api)
        await store.refresh()
        XCTAssertEqual(store.machines.count, 1)

        await api.setResult(.failure(.transport("offline")))
        await store.refresh()

        XCTAssertEqual(store.machines.map(\.slug), ["vm"])
    }

    // MARK: - setRcRoute

    func testSetRcRouteUpdatesTheSwitchedMachineFromWhatTheAgentReportsInForce() async throws {
        let api = FakeMachineDirectoryApi()
        await api.setResult(
            .success([makeMachine(slug: "vm", online: true), makeMachine(slug: "laptop", online: true)]))
        let store = MachineStore(api: api)
        await store.refresh()
        await api.setRcRouteResult(.success(AgentPatchResult(slug: "vm", rcRoute: .local)))

        try await store.setRcRoute(slug: "vm", route: .local)

        XCTAssertEqual(store.machines.first { $0.slug == "vm" }?.capabilities.rcRoute, .local)
        // The other machine's row is untouched — this is a per-machine switch.
        XCTAssertEqual(store.machines.first { $0.slug == "laptop" }?.capabilities.rcRoute, .anthropic)
        let calls = await api.rcRouteCalls
        XCTAssertEqual(calls.map(\.slug), ["vm"])
        XCTAssertEqual(calls.map(\.route), [.local])
    }

    func testSetRcRouteLeavesStateUntouchedAndRethrowsWhenTheAgentRefuses() async {
        let api = FakeMachineDirectoryApi()
        await api.setResult(.success([makeMachine(slug: "vm", online: true)]))
        let store = MachineStore(api: api)
        await store.refresh()
        await api.setRcRouteResult(.failure(.transport("Agent not connected")))

        do {
            try await store.setRcRoute(slug: "vm", route: .local)
            XCTFail("expected the refusal to propagate")
        } catch {
            // expected
        }

        XCTAssertEqual(store.machines.first { $0.slug == "vm" }?.capabilities.rcRoute, .anthropic)
    }
}

extension FakeMachineDirectoryApi {
    func setResult(_ result: Result<[Machine], PaiError>) {
        self.result = result
    }

    func setRcRouteResult(_ result: Result<AgentPatchResult, PaiError>) {
        self.rcRouteResult = result
    }
}
