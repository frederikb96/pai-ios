import XCTest
@testable import PAIKit

@MainActor
final class SessionStoreCreateSessionTests: XCTestCase {

    private func type(_ id: String) -> SessionType {
        SessionType(id: id, name: id, icon: "💬", workingDir: "/home/frederik")
    }

    private func machine(slug: String, types: [SessionType]) -> Machine {
        Machine(
            slug: slug, displayName: slug, online: true, lastSeenAt: nil, ingestEnabled: true,
            capabilities: .init(fastSessions: true, reboot: true, shell: true), sessionTypes: types
        )
    }

    // MARK: - Preselection

    /// The regression `SessionTypePicker.tsx` documents by name: the server's own default for an
    /// omitted `session_type` is the FIRST configured type, not `fast` — so the picker must write
    /// `fast` into the choice itself whenever it is available, not merely display it as selected.
    func testPreselectsFastWhenItIsAvailable() async {
        let machineApi = FakeMachineDirectoryApi()
        await machineApi.setResult(
            .success([machine(slug: "vm", types: [type("home"), type("fast"), type("custom")])]))
        let machines = MachineStore(api: machineApi)
        await machines.refresh()

        let store = CreateSessionStore(machines: machines, api: FakeCreateSessionApi())
        await store.start()

        XCTAssertEqual(store.selectedSessionTypeId, "fast")
    }

    /// A machine with no `fast` type at all falls back to the first configured one — never to
    /// `nil`, which would leave the create request omitting `session_type` and silently landing
    /// on whatever the SERVER'S first configured type is instead.
    func testFallsBackToTheFirstTypeWhenFastIsNotAvailable() async {
        let machineApi = FakeMachineDirectoryApi()
        await machineApi.setResult(.success([machine(slug: "vm", types: [type("home"), type("custom")])]))
        let machines = MachineStore(api: machineApi)
        await machines.refresh()

        let store = CreateSessionStore(machines: machines, api: FakeCreateSessionApi())
        await store.start()

        XCTAssertEqual(store.selectedSessionTypeId, "home")
    }

    func testNoTypesAvailableLeavesTheSelectionNil() async {
        let machineApi = FakeMachineDirectoryApi()
        await machineApi.setResult(.success([machine(slug: "vm", types: [])]))
        let machines = MachineStore(api: machineApi)
        await machines.refresh()

        let store = CreateSessionStore(machines: machines, api: FakeCreateSessionApi())
        await store.start()

        XCTAssertNil(store.selectedSessionTypeId)
    }

    /// The preselect effect must never override a choice already made — re-running it after the
    /// user already picked something (or after a custom directory set `sessionType` to
    /// `"custom"`) would silently undo their pick.
    func testPreselectionDoesNotOverrideAnExplicitChoice() async {
        let machineApi = FakeMachineDirectoryApi()
        await machineApi.setResult(.success([machine(slug: "vm", types: [type("home"), type("fast")])]))
        let machines = MachineStore(api: machineApi)
        await machines.refresh()

        let store = CreateSessionStore(machines: machines, api: FakeCreateSessionApi())
        store.selectSessionType("home")
        await store.start()

        XCTAssertEqual(store.selectedSessionTypeId, "home")
    }

    // MARK: - Machine switching clears type and directory

    func testSwitchingMachineClearsTypeAndDirectoryThenReselectsFast() async {
        let machineApi = FakeMachineDirectoryApi()
        await machineApi.setResult(
            .success([
                machine(slug: "vm", types: [type("fast")]),
                machine(slug: "laptop", types: [type("home"), type("fast")]),
            ])
        )
        let machines = MachineStore(api: machineApi)
        await machines.refresh()

        let store = CreateSessionStore(machines: machines, api: FakeCreateSessionApi())
        await store.start()
        store.selectWorkingDir("/home/frederik/pai-cloud")
        XCTAssertEqual(store.selectedSessionTypeId, "custom")
        XCTAssertNotNil(store.workingDir)

        store.selectMachine("laptop")

        XCTAssertEqual(store.selectedMachine, "laptop")
        XCTAssertNil(store.workingDir)
        // Re-preselected for the NEW machine's own type list, not left nil.
        XCTAssertEqual(store.selectedSessionTypeId, "fast")
    }

    // MARK: - selectWorkingDir couples directory and type

    func testSelectingAWorkingDirectorySetsTypeToCustom() {
        let store = CreateSessionStore(
            machines: MachineStore(api: FakeMachineDirectoryApi()), api: FakeCreateSessionApi())
        store.selectWorkingDir("/home/frederik/pai-cloud")

        XCTAssertEqual(store.workingDir, "/home/frederik/pai-cloud")
        XCTAssertEqual(store.selectedSessionTypeId, "custom")
    }

    func testClearingTheWorkingDirectoryDropsTypeBackToNil() async {
        let machineApi = FakeMachineDirectoryApi()
        await machineApi.setResult(.success([machine(slug: "vm", types: [type("fast")])]))
        let machines = MachineStore(api: machineApi)
        await machines.refresh()

        let store = CreateSessionStore(machines: machines, api: FakeCreateSessionApi())
        store.selectWorkingDir("/home/frederik/pai-cloud")
        XCTAssertEqual(store.selectedSessionTypeId, "custom")

        store.selectWorkingDir(nil)

        // Clearing re-admits the preselect rule immediately rather than leaving the choice empty.
        XCTAssertEqual(store.selectedSessionTypeId, "fast")
    }

    // MARK: - primary vs. environment session types

    /// Freddy's own wording: the top-level picker keeps only home/fast; everything else a
    /// machine offers surfaces inside the Custom directory browser instead.
    func testPrimaryTypesAreOnlyHomeAndFastEverythingElseIsAnEnvironment() async {
        let machineApi = FakeMachineDirectoryApi()
        await machineApi.setResult(
            .success([machine(slug: "vm", types: [type("home"), type("fast"), type("websearch")])]))
        let machines = MachineStore(api: machineApi)
        await machines.refresh()

        let store = CreateSessionStore(machines: machines, api: FakeCreateSessionApi())
        await store.start()

        XCTAssertEqual(store.primarySessionTypes.map(\.id), ["home", "fast"])
        XCTAssertEqual(store.environmentSessionTypes.map(\.id), ["websearch"])
    }

    // MARK: - reset

    func testResetReturnsToDefaultMachineWithNoTypeOrDirectory() {
        let store = CreateSessionStore(
            machines: MachineStore(api: FakeMachineDirectoryApi()), api: FakeCreateSessionApi())
        store.selectMachine("laptop")
        store.selectWorkingDir("/home/frederik/x")

        store.reset()

        XCTAssertEqual(store.selectedMachine, MachineStore.defaultMachineSlug)
        XCTAssertNil(store.selectedSessionTypeId)
        XCTAssertNil(store.workingDir)
    }

    // MARK: - create()

    func testCreateSendsTheSelectedMachineTypeAndDirectory() async {
        let api = FakeCreateSessionApi()
        let store = CreateSessionStore(machines: MachineStore(api: FakeMachineDirectoryApi()), api: api)
        store.selectMachine("laptop")
        store.selectWorkingDir("/home/frederik/pai-cloud")

        _ = await store.create(message: "hello")

        let calls = await api.postMessageCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].agent, "laptop")
        XCTAssertEqual(calls[0].sessionType, "custom")
        XCTAssertEqual(calls[0].workingDir, "/home/frederik/pai-cloud")
        XCTAssertNil(calls[0].sessionId, "omitting session_id is what makes this endpoint CREATE")
    }

    func testCreateReturnsAnOptimisticSessionMatchingWhatWasSent() async {
        let api = FakeCreateSessionApi()
        await api.setPostMessageResult(.success(PostMessageResponse(sessionId: "new-id", messageId: 1)))
        let store = CreateSessionStore(machines: MachineStore(api: FakeMachineDirectoryApi()), api: api)
        store.selectMachine("vm")
        store.selectSessionType("fast")

        let result = await store.create(message: "hello there")

        guard case let .created(session) = result else { return XCTFail("expected .created, got \(result)") }
        XCTAssertEqual(session.id, "new-id")
        XCTAssertEqual(session.initialMessage, "hello there")
        XCTAssertEqual(session.state, .starting)
        XCTAssertEqual(session.status, .pending)
        XCTAssertEqual(session.sessionType, "fast")
        XCTAssertEqual(session.agent, "vm")
        XCTAssertEqual(session.kind, .conversation)
    }

    func testCreateFailureSurfacesTheServerDetailAndLeavesChoicesIntact() async {
        let api = FakeCreateSessionApi()
        await api.setPostMessageResult(
            .failure(.detail("Maximum concurrent sessions on 'vm' (50) reached.", statusCode: 429)))
        let store = CreateSessionStore(machines: MachineStore(api: FakeMachineDirectoryApi()), api: api)
        store.selectWorkingDir("/home/frederik/pai-cloud")

        let result = await store.create(message: "hello")

        guard case let .failed(message) = result else { return XCTFail("expected .failed, got \(result)") }
        XCTAssertEqual(message, "Maximum concurrent sessions on 'vm' (50) reached.")
        // The screen stays put on failure — nothing about the in-progress choice is cleared.
        XCTAssertEqual(store.workingDir, "/home/frederik/pai-cloud")
    }

    func testCreateSendsTheSelectedModel() async {
        let api = FakeCreateSessionApi()
        let store = CreateSessionStore(machines: MachineStore(api: FakeMachineDirectoryApi()), api: api)
        store.selectModel("opus")

        _ = await store.create(message: "hello")

        let calls = await api.postMessageCalls
        XCTAssertEqual(calls[0].model, "opus")
    }

    func testCreateOmitsTheModelWhenNoneWasChosen() async {
        let api = FakeCreateSessionApi()
        let store = CreateSessionStore(machines: MachineStore(api: FakeMachineDirectoryApi()), api: api)

        _ = await store.create(message: "hello")

        let calls = await api.postMessageCalls
        XCTAssertNil(calls[0].model)
    }

    func testIsCreatingIsTrueOnlyWhileTheRequestIsInFlight() async {
        let api = FakeCreateSessionApi()
        let store = CreateSessionStore(machines: MachineStore(api: FakeMachineDirectoryApi()), api: api)
        XCTAssertFalse(store.isCreating)

        _ = await store.create(message: "hello")

        XCTAssertFalse(store.isCreating)
    }
}

extension FakeCreateSessionApi {
    func setPostMessageResult(_ result: Result<PostMessageResponse, PaiError>) {
        postMessageResult = result
    }
}
