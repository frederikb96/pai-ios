import Foundation
import XCTest

@testable import PAIKit

/// One `actor` fake scripting both calls `ArcSpecStore.load()` makes, matching
/// `ArcSpecListStoreTests`'s own `FakeArcSpecListApi` shape.
private actor FakeArcSpecApi: ArcSpecApiClient {
    var specResult: Result<ArcSpec, PaiError> = .failure(.transport("unset"))
    var recoverResult: Result<ArcRecoverPayload, PaiError> = .failure(.transport("unset"))
    private(set) var specCallCount = 0

    func setSpecResult(_ result: Result<ArcSpec, PaiError>) {
        specResult = result
    }

    func setRecoverResult(_ result: Result<ArcRecoverPayload, PaiError>) {
        recoverResult = result
    }

    func getArcSpec(uuid: String) async throws -> ArcSpec {
        specCallCount += 1
        switch specResult {
        case .success(let spec): return spec
        case .failure(let error): throw error
        }
    }

    func getArcRecover(specUuid: String) async throws -> ArcRecoverPayload {
        switch recoverResult {
        case .success(let payload): return payload
        case .failure(let error): throw error
        }
    }
}

private func makeSpec(sessions: [String]) -> ArcSpec {
    ArcSpec(
        uuid: "spec-1", name: "Demo", phase: "Build", effort: 1, projectId: nil, sessions: sessions,
        overview: nil, createdAt: "2026-09-01T00:00:00.000000+00:00", updatedAt: "2026-09-01T00:00:00.000000+00:00")
}

private func makeRecover(name: String = "Demo") -> ArcRecoverPayload {
    ArcRecoverPayload(
        spec: "spec-1", name: name, overview: "An overview", phase: "Build",
        activeSegment: ArcActiveSegment(index: 0, blocks: [], loose: [], busyAgents: []), rows: [:])
}

@MainActor
final class ArcSpecStoreTests: XCTestCase {

    /// A successful load carries both the recovered timeline AND the spec's own `sessions` list
    /// — the field `ArcSubagentLookup.resolveBoundSessionId` needs and `getArcRecover` alone
    /// never supplies.
    func testLoadPopulatesBoundSessionsFromTheSpecFetch() async {
        let api = FakeArcSpecApi()
        await api.setSpecResult(.success(makeSpec(sessions: ["conv-a", "conv-b"])))
        await api.setRecoverResult(.success(makeRecover()))
        let store = ArcSpecStore(specUuid: "spec-1", api: api)

        await store.load()

        XCTAssertEqual(store.boundSessions, ["conv-a", "conv-b"])
        XCTAssertEqual(store.name, "Demo")
        XCTAssertNil(store.errorMessage)
    }

    /// The spec fetch failing must fail the whole load — a screen showing rows from `recover`
    /// with a stale or empty `boundSessions` would silently break every badge tap on it.
    func testLoadFailsWhenTheSpecFetchFailsEvenIfRecoverSucceeds() async {
        let api = FakeArcSpecApi()
        await api.setSpecResult(.failure(.transport("offline")))
        await api.setRecoverResult(.success(makeRecover()))
        let store = ArcSpecStore(specUuid: "spec-1", api: api)

        await store.load()

        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(store.timeline)
        XCTAssertTrue(store.boundSessions.isEmpty)
    }

    /// A background refresh (poll tick, live SSE signal) must not re-request `boundSessions` —
    /// only `recover` needs to stay current while a spec is on screen.
    func testRefreshQuietlyDoesNotRefetchTheSpec() async {
        let api = FakeArcSpecApi()
        await api.setSpecResult(.success(makeSpec(sessions: ["conv-a"])))
        await api.setRecoverResult(.success(makeRecover()))
        let store = ArcSpecStore(specUuid: "spec-1", api: api)
        await store.load()

        await api.setRecoverResult(.success(makeRecover(name: "Demo (refreshed)")))
        await store.refreshQuietly()

        XCTAssertEqual(store.name, "Demo (refreshed)")
        XCTAssertEqual(store.boundSessions, ["conv-a"], "boundSessions must survive a recover-only refresh")
        let specCalls = await api.specCallCount
        XCTAssertEqual(specCalls, 1, "refreshQuietly must not re-fetch the spec")
    }
}
