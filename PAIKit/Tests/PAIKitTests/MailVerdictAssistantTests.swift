import XCTest

@testable import PAIKit

/// The MailVerdict assistant is a pod-resident API session like ultra-fast, with a model catalogue
/// of its own.
@MainActor
final class MailVerdictAssistantTests: XCTestCase {
    private let ultrafast = ApiSessionCatalog(
        defaultModel: "claude-haiku-5-5", defaultThinking: "none",
        models: [UltraFastModelInfo(id: "claude-haiku-5-5", provider: "anthropic", effortLevels: ["none"])])
    private let assistant = ApiSessionCatalog(
        defaultModel: "claude-opus-5-5", defaultThinking: "low",
        models: [
            UltraFastModelInfo(id: "claude-opus-5-5", provider: "anthropic", effortLevels: ["none", "low"])
        ])

    private func makeStore() async -> CreateSessionStore {
        let api = FakeCreateSessionApi()
        await api.setSessionModelsResult(.success([]), ultrafast: ultrafast, mailverdict: assistant)
        let store = CreateSessionStore(machines: MachineStore(api: FakeMachineDirectoryApi()), api: api)
        await store.start()
        return store
    }

    func testTheKindDecodesAndIsPodResident() async throws {
        let kind = try JSONDecoder().decode(SessionKind.self, from: Data(#""mailverdict""#.utf8))
        XCTAssertEqual(kind, .mailverdict)
        XCTAssertTrue(sessionKindsPodResident.contains(.mailverdict))
        XCTAssertFalse(sessionKindsWithoutProcess.contains(.mailverdict))
        XCTAssertTrue(SessionModelSwitch.canSwitch(SessionFixture.make(kind: .mailverdict)))
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(kind), as: UTF8.self), #""mailverdict""#)
    }

    func testTheNewSessionScreenReadsTheAssistantsOwnCatalogue() async {
        let store = await makeStore()
        store.selectSessionType("mailverdict")
        XCTAssertTrue(store.isMailVerdictSelected)
        XCTAssertTrue(store.isApiSessionSelected)
        XCTAssertFalse(store.isUltrafastSelected)
        XCTAssertEqual(store.resolvedModel, "claude-opus-5-5")
        XCTAssertEqual(store.resolvedThinking, "low")
        XCTAssertEqual(store.pickerModels.map(\.id), ["claude-opus-5-5"])

        store.selectSessionType("ultrafast")
        XCTAssertEqual(store.resolvedModel, "claude-haiku-5-5")
        XCTAssertEqual(store.pickerModels.map(\.id), ["claude-haiku-5-5"])
    }

    func testAPickDoesNotCrossBetweenTheTwoCatalogues() async {
        let store = await makeStore()
        store.selectSessionType("ultrafast")
        store.selectModel("claude-haiku-5-5")
        store.selectSessionType("mailverdict")
        XCTAssertNil(store.selectedModel)
        XCTAssertNil(store.selectedThinking)
    }

    func testTheCreateRequestCarriesTheTypeButNoDirectoryAndNoForeignModel() async {
        let store = await makeStore()
        store.selectWorkingDir("/home/frederik/old-project")
        store.selectSessionType("ultrafast")
        store.selectModel("claude-haiku-5-5")
        store.selectSessionType("mailverdict")
        let sending = FakeOutboxSending()
        let outbox = OutboxStore(api: sending, storage: OutboxInMemoryStorage())
        store.enqueueSend(message: "what is on my calendar", outbox: outbox)
        for _ in 0..<400 where await sending.postMessageCalls.isEmpty { await Task.yield() }
        let calls = await sending.postMessageCalls
        XCTAssertEqual(calls.first?.sessionType, "mailverdict")
        XCTAssertNil(calls.first?.workingDir)
        XCTAssertNil(calls.first?.model)
    }

    func testTheSettingsBlockAndItsUpdateRoundTrip() async throws {
        let json = """
            {"ultrafast":{"model":"m","reasoning_effort":"low","models":{}},
             "fast":{"model":"sonnet","thinking":"low","models":{}},
             "mailverdict":{"model":"claude-opus-5-5","reasoning_effort":"low",
                            "models":{"claude-opus-5-5":{"provider":"anthropic","efforts":["low","none"]}}}}
            """
        let defaults = try JSONDecoder().decode(SessionDefaults.self, from: Data(json.utf8))
        XCTAssertEqual(defaults.mailverdict?.model, "claude-opus-5-5")
        let older = """
            {"ultrafast":{"model":"m","reasoning_effort":"low","models":{}},"fast":{"model":"sonnet","thinking":"low","models":{}}}
            """
        XCTAssertNil(try JSONDecoder().decode(SessionDefaults.self, from: Data(older.utf8)).mailverdict)

        let update = try JSONEncoder().encode(SessionDefaultsUpdate(mailverdictModel: "claude-opus-5-5"))
        let sent = try JSONSerialization.jsonObject(with: update) as? [String: String]
        XCTAssertEqual(sent, ["mailverdict_model": "claude-opus-5-5"])
    }
}
