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
            capabilities: .init(fastSessions: true, reboot: true, shell: true, rcLocal: true),
            sessionTypes: types
        )
    }

    // MARK: - Preselection

    /// The regression `SessionTypePicker.tsx` documents by name: the server's own default for an
    /// omitted `session_type` is the FIRST configured type, which happens to be `home` too — so
    /// the picker must write `home` into the choice itself whenever it is available, not merely
    /// display it as selected.
    func testPreselectsHomeWhenItIsAvailable() async {
        let machineApi = FakeMachineDirectoryApi()
        await machineApi.setResult(
            .success([machine(slug: "vm", types: [type("fast"), type("home"), type("custom")])]))
        let machines = MachineStore(api: machineApi)
        await machines.refresh()

        let store = CreateSessionStore(machines: machines, api: FakeCreateSessionApi())
        await store.start()

        XCTAssertEqual(store.selectedSessionTypeId, "home")
    }

    /// A machine with no `home` type at all falls back to the first configured one — never to
    /// `nil`, which would leave the create request omitting `session_type` and silently landing
    /// on whatever the SERVER'S first configured type is instead.
    func testFallsBackToTheFirstTypeWhenHomeIsNotAvailable() async {
        let machineApi = FakeMachineDirectoryApi()
        await machineApi.setResult(.success([machine(slug: "vm", types: [type("fast"), type("custom")])]))
        let machines = MachineStore(api: machineApi)
        await machines.refresh()

        let store = CreateSessionStore(machines: machines, api: FakeCreateSessionApi())
        await store.start()

        XCTAssertEqual(store.selectedSessionTypeId, "fast")
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

    func testSwitchingMachineClearsTypeAndDirectoryThenReselectsHome() async {
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
        XCTAssertEqual(store.selectedSessionTypeId, "home")
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

    /// A deny list, not an allow list — a second ConfigMap-defined type (anything other than the
    /// one built-in id this sinks) stays at the top level automatically, with no change needed
    /// here to admit it.
    func testASecondConfigMapTypeStaysAtTheTopLevel() async {
        let machineApi = FakeMachineDirectoryApi()
        await machineApi.setResult(
            .success([machine(slug: "vm", types: [type("home"), type("work"), type("fast"), type("websearch")])]))
        let machines = MachineStore(api: machineApi)
        await machines.refresh()

        let store = CreateSessionStore(machines: machines, api: FakeCreateSessionApi())
        await store.start()

        XCTAssertEqual(store.primarySessionTypes.map(\.id), ["home", "work", "fast"])
        XCTAssertEqual(store.environmentSessionTypes.map(\.id), ["websearch"])
    }

    /// The confined environment sinks the same way websearch does, alongside it — it is
    /// selectable by directory, not disposable like `fast`, so it belongs in the Custom browser
    /// rather than at the top level.
    func testConfinedSinksAlongsideWebsearch() async {
        let machineApi = FakeMachineDirectoryApi()
        await machineApi.setResult(
            .success([machine(slug: "vm", types: [type("home"), type("fast"), type("websearch"), type("confined")])]))
        let machines = MachineStore(api: machineApi)
        await machines.refresh()

        let store = CreateSessionStore(machines: machines, api: FakeCreateSessionApi())
        await store.start()

        XCTAssertEqual(store.primarySessionTypes.map(\.id), ["home", "fast"])
        XCTAssertEqual(store.environmentSessionTypes.map(\.id), ["websearch", "confined"])
    }

    /// The supervisor is opened only from the session it watches — a pill for it here would let
    /// it be launched like an ordinary session. It must never appear, top-level or sunk, even if
    /// the backend lists it as a type.
    func testSupervisorIsNeverOfferedEvenIfTheBackendListsIt() async {
        let machineApi = FakeMachineDirectoryApi()
        await machineApi.setResult(
            .success([machine(slug: "vm", types: [type("home"), type("fast"), type("supervisor")])]))
        let machines = MachineStore(api: machineApi)
        await machines.refresh()

        let store = CreateSessionStore(machines: machines, api: FakeCreateSessionApi())
        await store.start()

        XCTAssertEqual(store.primarySessionTypes.map(\.id), ["home", "fast"])
        XCTAssertEqual(store.environmentSessionTypes, [])
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

    // MARK: - enqueueSend()

    /// The send goes through an `OutboxStore`, which is what makes it durable before the network
    /// is ever touched. Every test below builds a fresh one against an in-memory backing store,
    /// matching how the app wires the real disk-backed one.
    ///
    /// What happens once a send *lands* — the row, the id reaching the screen — is the outbox
    /// handover's, and is covered in `NewSessionFlowTests`. These cover only what this store puts
    /// on the wire, which is the launch choice it is the sole owner of.
    private func makeOutbox(_ api: FakeOutboxSending) -> OutboxStore {
        OutboxStore(api: api, storage: OutboxInMemoryStorage())
    }

    /// The outbox sends on its own worker, so a test asserting on what left has to wait for it.
    /// 🚨 Hold the `OutboxStore` in a local while doing so: its worker task holds it weakly, so a
    /// store passed straight into `enqueueSend` as a temporary can be released before the send it
    /// was handed ever leaves — a test that then reads no calls at all.
    private func waitForPost(_ sending: FakeOutboxSending, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await sending.postMessageCalls.isEmpty, Date() < deadline {
            await Task.yield()
        }
    }

    func testEnqueueSendsTheSelectedMachineTypeAndDirectory() async {
        let api = FakeCreateSessionApi()
        let sending = FakeOutboxSending()
        let store = CreateSessionStore(machines: MachineStore(api: FakeMachineDirectoryApi()), api: api)
        store.selectMachine("laptop")
        store.selectWorkingDir("/home/frederik/pai-cloud")

        let outbox = makeOutbox(sending)
        store.enqueueSend(message: "hello", outbox: outbox)

        await waitForPost(sending)
        let calls = await sending.postMessageCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].agent, "laptop")
        XCTAssertEqual(calls[0].sessionType, "custom")
        XCTAssertEqual(calls[0].workingDir, "/home/frederik/pai-cloud")
        XCTAssertNil(calls[0].sessionId, "omitting session_id is what makes this endpoint CREATE")
    }

    /// 🚨 Returns without waiting for the network, deliberately: the entry is already on disk, and
    /// the screen has a queued bubble to show for it. Awaiting the entry instead cannot work — the
    /// handover retires it the instant it is sent, so a poll for its `.sent` state finds nothing.
    func testEnqueueReturnsBeforeTheRequestHasEvenLeft() async {
        let api = FakeCreateSessionApi()
        let sending = FakeOutboxSending()
        let outbox = makeOutbox(sending)
        let store = CreateSessionStore(machines: MachineStore(api: FakeMachineDirectoryApi()), api: api)

        store.enqueueSend(message: "hello", outbox: outbox)

        // Read with no await in between: the queue is populated by the time `enqueueSend`
        // returns, which is what lets the composer clear and the bubble appear in one frame.
        XCTAssertEqual(outbox.newSessionEntries().count, 1)
        XCTAssertEqual(outbox.newSessionEntries().first?.text, "hello")
    }

    /// Selecting the pod-resident type must post exactly that string, however it reached the
    /// picker — a hardcoded quick action and a backend-sourced pill both just call
    /// `selectSessionType("ultrafast")`, and this is what the request actually carries.
    func testEnqueueSendsUltrafastWhenSelected() async {
        let api = FakeCreateSessionApi()
        let sending = FakeOutboxSending()
        let store = CreateSessionStore(machines: MachineStore(api: FakeMachineDirectoryApi()), api: api)
        store.selectSessionType("ultrafast")
        XCTAssertTrue(store.isUltrafastSelected)

        let outbox = makeOutbox(sending)
        store.enqueueSend(message: "hello", outbox: outbox)

        await waitForPost(sending)
        let calls = await sending.postMessageCalls
        XCTAssertEqual(calls[0].sessionType, "ultrafast")
    }

    func testEnqueueSendsTheSelectedModel() async {
        let api = FakeCreateSessionApi()
        let sending = FakeOutboxSending()
        let store = CreateSessionStore(machines: MachineStore(api: FakeMachineDirectoryApi()), api: api)
        store.selectModel("opus")

        let outbox = makeOutbox(sending)
        store.enqueueSend(message: "hello", outbox: outbox)

        await waitForPost(sending)
        let calls = await sending.postMessageCalls
        XCTAssertEqual(calls[0].model, "opus")
    }

    func testEnqueueOmitsTheModelWhenNoneWasChosen() async {
        let api = FakeCreateSessionApi()
        let sending = FakeOutboxSending()
        let store = CreateSessionStore(machines: MachineStore(api: FakeMachineDirectoryApi()), api: api)

        let outbox = makeOutbox(sending)
        store.enqueueSend(message: "hello", outbox: outbox)

        await waitForPost(sending)
        let calls = await sending.postMessageCalls
        XCTAssertNil(calls[0].model)
    }

    // MARK: - thinking

    func testCreateSendsTheSelectedThinkingLevel() async {
        let api = FakeCreateSessionApi()
        let sending = FakeOutboxSending()
        let store = CreateSessionStore(machines: MachineStore(api: FakeMachineDirectoryApi()), api: api)
        store.selectModel("opus")
        store.selectThinking("high")

        let outbox = makeOutbox(sending)
        store.enqueueSend(message: "hello", outbox: outbox)

        await waitForPost(sending)
        let calls = await sending.postMessageCalls
        XCTAssertEqual(calls[0].thinking, "high")
    }

    func testChoosingADifferentModelClearsAPreviouslyChosenThinkingLevel() {
        let store = CreateSessionStore(
            machines: MachineStore(api: FakeMachineDirectoryApi()), api: FakeCreateSessionApi())
        store.selectModel("sonnet")
        store.selectThinking("high")

        store.selectModel("opus")

        XCTAssertNil(store.selectedThinking)
    }

    func testResolvedModelAndThinkingAreNilByDefaultOnAnOrdinarySession() {
        let store = CreateSessionStore(
            machines: MachineStore(api: FakeMachineDirectoryApi()), api: FakeCreateSessionApi())
        store.selectSessionType("home")

        XCTAssertNil(store.resolvedModel)
        XCTAssertNil(store.resolvedThinking)
    }

    /// A fast session's own default — mid-sized model, low effort — must be what a picker shows
    /// pre-selected, without ever being written into `selectedModel`/`selectedThinking` unless
    /// Freddy actually picks it: "a fast session created with no choice still runs as it does
    /// today" depends on the launch flags staying omitted.
    func testResolvedModelAndThinkingFallBackToTheFastDefaultOnAFastSessionWithNoChoiceMade() {
        let store = CreateSessionStore(
            machines: MachineStore(api: FakeMachineDirectoryApi()), api: FakeCreateSessionApi())
        store.selectSessionType("fast")

        XCTAssertEqual(store.resolvedModel, store.fastDefaultModel)
        XCTAssertEqual(store.resolvedThinking, store.fastDefaultThinking)
        XCTAssertNil(store.selectedModel)
        XCTAssertNil(store.selectedThinking)
    }

    /// The default pair rides `GET /api/session-models` rather than a hardcoded value — a picker
    /// that hand-mirrored it would show the old default and write nothing to the draft the
    /// moment the agent's actual default changed underneath it.
    func testFastDefaultPairComesFromTheFetchedResponseNotAHardcodedValue() async {
        let api = FakeCreateSessionApi()
        await api.setSessionModelsResult(.success([]), fastDefaultModel: "opus", fastDefaultThinking: "high")
        let store = CreateSessionStore(machines: MachineStore(api: FakeMachineDirectoryApi()), api: api)
        store.selectSessionType("fast")

        await store.start()

        XCTAssertEqual(store.fastDefaultModel, "opus")
        XCTAssertEqual(store.fastDefaultThinking, "high")
        XCTAssertEqual(store.resolvedModel, "opus")
        XCTAssertEqual(store.resolvedThinking, "high")
    }

    func testAnExplicitChoiceOnAFastSessionOverridesTheDefaultAndIsWhatGetsSent() async {
        let api = FakeCreateSessionApi()
        let sending = FakeOutboxSending()
        let store = CreateSessionStore(machines: MachineStore(api: FakeMachineDirectoryApi()), api: api)
        store.selectSessionType("fast")
        store.selectModel("opus")

        XCTAssertEqual(store.resolvedModel, "opus")
        let outbox = makeOutbox(sending)
        store.enqueueSend(message: "hello", outbox: outbox)

        await waitForPost(sending)
        let calls = await sending.postMessageCalls
        XCTAssertEqual(calls[0].model, "opus")
    }

    func testEffortLevelsForResolvedModelReadsTheDeclaredVocabularyRatherThanAHandMirroredList() async {
        let api = FakeCreateSessionApi()
        await api.setSessionModelsResult(
            .success([
                SessionModelInfo(id: "haiku", effortLevels: []),
                SessionModelInfo(id: "sonnet", effortLevels: ["low", "medium", "high", "xhigh", "max"]),
            ]))
        let store = CreateSessionStore(machines: MachineStore(api: FakeMachineDirectoryApi()), api: api)
        await store.start()

        store.selectModel("sonnet")
        XCTAssertEqual(store.effortLevelsForResolvedModel, ["low", "medium", "high", "xhigh", "max"])

        store.selectModel("haiku")
        XCTAssertEqual(store.effortLevelsForResolvedModel, [])
    }

}

extension FakeOutboxSending {
    func setPostMessageResult(_ result: Result<PostMessageResponse, PaiError>) {
        postMessageResult = result
    }
}

extension FakeCreateSessionApi {
    func setSessionModelsResult(
        _ result: Result<[SessionModelInfo], PaiError>,
        fastDefaultModel: String = "sonnet", fastDefaultThinking: String = "low"
    ) {
        sessionModelsResult = result.map {
            SessionModelsResponse(
                models: $0, fastDefaultModel: fastDefaultModel, fastDefaultThinking: fastDefaultThinking)
        }
    }
}
