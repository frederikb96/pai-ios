import XCTest

@testable import PAIKit

/// A Hermes model entry must stay startable while Claude is signed out, and it is not an API
/// session (it keeps the ordinary composer, files and model picker). Older servers send no
/// `label`/`engine`, so the `hermes:` id prefix has to carry the same answer.
@MainActor
final class HermesModelEntryTests: XCTestCase {
    private func makeStore(models: [SessionModelInfo]) async -> CreateSessionStore {
        let api = FakeCreateSessionApi()
        await api.setSessionModelsResult(.success(models))
        let store = CreateSessionStore(machines: MachineStore(api: FakeMachineDirectoryApi()), api: api)
        await store.start()
        return store
    }

    private func auth(loggedIn: Bool?) -> ClaudeAuth {
        ClaudeAuth(
            known: true, loggedIn: loggedIn, health: nil, subscription: nil,
            accessExpiresAt: nil, refreshExpiresAt: nil, login: nil, lastError: nil, reportedAt: nil)
    }

    private let entries = [
        SessionModelInfo(id: "sonnet", effortLevels: ["low"], label: "Sonnet", engine: "claude"),
        SessionModelInfo(id: "hermes:kimi", effortLevels: [], label: "Hermes · Kimi", engine: "hermes"),
    ]

    func testHermesEntryStartsWhileSignedOutButClaudeEntriesDoNot() async {
        let store = await makeStore(models: entries)
        let signedOut = auth(loggedIn: false)
        store.selectSessionType("home")

        XCTAssertTrue(store.signInBlocksStart(signedOut))

        store.selectModel("hermes:kimi")
        XCTAssertTrue(store.isHermesModelSelected)
        XCTAssertFalse(store.isApiSessionSelected)
        XCTAssertFalse(store.signInBlocksStart(signedOut))

        store.selectModel("sonnet")
        XCTAssertTrue(store.signInBlocksStart(signedOut))
        XCTAssertFalse(store.signInBlocksStart(auth(loggedIn: true)))
    }

    func testTheServedEngineDecidesNotTheIdPrefix() async {
        let store = await makeStore(models: [
            SessionModelInfo(id: "hermes:odd", effortLevels: [], label: "Odd", engine: "claude")
        ])
        store.selectSessionType("home")
        store.selectModel("hermes:odd")

        XCTAssertFalse(store.isHermesModelSelected)
        XCTAssertTrue(store.signInBlocksStart(auth(loggedIn: false)))
    }

    func testAnOldServerEntryWithoutEngineOrLabelFallsBackToThePrefixAndTheId() throws {
        let json =
            #"{"models":[{"id":"hermes:sonnet","effort_levels":[]},{"id":"opus","effort_levels":["low"]}],"#
            + #""fast_default_model":"sonnet","fast_default_thinking":"low"}"#
        let response = try JSONDecoder().decode(SessionModelsResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.models.map(\.engine), ["hermes", "claude"])
        XCTAssertEqual(response.models.map(\.label), [nil, nil])
    }

    func testThePickerShowsTheServedLabelAndOffersHermesOnlyWhereItCanStart() async {
        let store = await makeStore(models: entries)
        store.selectSessionType("home")

        XCTAssertEqual(store.pickerModels.map(\.id), ["sonnet", "hermes:kimi"])
        XCTAssertEqual(store.modelLabel("hermes:kimi"), "Hermes · Kimi")
        XCTAssertEqual(store.modelLabel("sonnet"), "Sonnet")

        store.selectSessionType("fast")
        XCTAssertEqual(store.pickerModels.map(\.id), ["sonnet"])
    }

    func testChoosingAnotherTypeDropsAHermesChoiceTheTypeCannotStart() async {
        let store = await makeStore(models: entries)
        store.selectSessionType("custom")
        store.selectModel("hermes:kimi")

        store.selectSessionType("home")
        XCTAssertEqual(store.selectedModel, "hermes:kimi")

        store.selectSessionType("fast")
        XCTAssertNil(store.selectedModel)
    }

    func testAHermesSessionIsLabelledByItsRoute() {
        XCTAssertEqual(SessionModelSwitch.aliasLabel("hermes:kimi"), "Hermes · Kimi")
        let session = SessionFixture.make(model: "hermes:kimi")
        XCTAssertEqual(SessionModelSwitch.badgeLabel(session, live: nil), "Hermes · Kimi")
    }
}
