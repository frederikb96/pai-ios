import XCTest

@testable import PAIKit

@MainActor
final class SessionDefaultsStoreTests: XCTestCase {
    private static let defaults = SessionDefaults(
        ultrafast: .init(
            model: "claude-haiku-5-5", reasoningEffort: "none",
            models: [
                "google/gemma-4-31B-it": .init(provider: "infomaniak", efforts: ["none"]),
                "claude-opus-5-5": .init(provider: "anthropic", efforts: ["high", "low"]),
                "claude-haiku-5-5": .init(provider: "anthropic", efforts: ["medium", "none", "low"]),
            ]),
        fast: .init(model: "sonnet", thinking: "low", models: ["sonnet": ["low", "high"], "opus": ["low"]]))

    func testClaudeModelsComeFirstAndEffortsCheapestFirst() async {
        let store = SessionDefaultsStore(api: FakeSessionDefaultsApi())

        await store.load()

        XCTAssertEqual(
            store.ultrafastModelIds, ["claude-haiku-5-5", "claude-opus-5-5", "google/gemma-4-31B-it"])
        XCTAssertEqual(store.ultrafastEfforts, ["none", "low", "medium"])
        XCTAssertEqual(store.fastModels, ["sonnet", "opus"])
    }

    func testARefusedPickKeepsTheServersValueAndSaysWhy() async {
        let api = FakeSessionDefaultsApi()
        let store = SessionDefaultsStore(api: api)
        await store.load()
        await api.refuse()

        await store.save(SessionDefaultsUpdate(fastModel: "opus"))

        XCTAssertEqual(store.defaults?.fast.model, "sonnet")
        XCTAssertNotNil(store.errorMessage)
    }

    func testAnUpdateSendsOnlyWhatChanged() throws {
        let body = try JSONEncoder().encode(SessionDefaultsUpdate(fastThinking: "high"))

        let json = try JSONSerialization.jsonObject(with: body) as? [String: String]
        XCTAssertEqual(json, ["fast_thinking": "high"])
    }

    fileprivate static var fixture: SessionDefaults { defaults }
}

private actor FakeSessionDefaultsApi: SessionDefaultsApiClient {
    private var refuses = false

    func refuse() { refuses = true }

    func getSessionDefaults() async throws -> SessionDefaults { await SessionDefaultsStoreTests.fixture }

    func updateSessionDefaults(_ update: SessionDefaultsUpdate) async throws -> SessionDefaults {
        if refuses { throw PaiError.detail("refused", statusCode: 400) }
        return await SessionDefaultsStoreTests.fixture
    }
}
