import Foundation
import XCTest

@testable import PAIKit

private actor FakeSkillApi: SkillApiClient {
    var results: [Result<SkillListing, PaiError>] = []
    private(set) var asked: [SkillContext] = []
    private let delay: Duration

    init(delay: Duration = .zero) { self.delay = delay }

    func queue(_ result: Result<SkillListing, PaiError>) { results.append(result) }

    func getSkills(for context: SkillContext) async throws -> SkillListing {
        asked.append(context)
        try? await Task.sleep(for: delay)
        return try (results.isEmpty ? .success(SkillListing(skills: [], updatedAt: nil)) : results.removeFirst()).get()
    }
}

private final class Clock: @unchecked Sendable {
    var current = Date(timeIntervalSince1970: 1_000)
    func read() -> Date { current }
}

private func listing(_ names: [String]) -> SkillListing {
    SkillListing(skills: names.map { SkillEntry(name: $0, description: "") }, updatedAt: "2026-10-22T10:00:00+00:00")
}

@MainActor
final class SkillStoreTests: XCTestCase {
    private let session = SkillContext.session("s1")

    func testNamesAreKeptPerContext() async {
        let api = FakeSkillApi()
        await api.queue(.success(listing(["dummy"])))
        await api.queue(.success(listing(["arc"])))
        let store = SkillStore(api: api)
        let other = SkillContext.newSession(agent: "vm", sessionType: "home", workingDir: nil)

        await store.load(session)
        await store.load(other)

        XCTAssertEqual(store.names(for: session), ["dummy"])
        XCTAssertEqual(store.names(for: other), ["arc"])
        XCTAssertEqual(store.names(for: nil), [])
    }

    func testAFreshListingIsNotFetchedAgainButAStaleOneIs() async {
        let api = FakeSkillApi()
        await api.queue(.success(listing(["dummy"])))
        await api.queue(.success(listing(["dummy", "arc"])))
        let clock = Clock()
        let store = SkillStore(api: api, now: { clock.read() })

        await store.load(session)
        clock.current.addTimeInterval(30)
        await store.load(session)
        var asked = await api.asked.count
        XCTAssertEqual(asked, 1)

        clock.current.addTimeInterval(60)
        await store.load(session)
        asked = await api.asked.count
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(store.names(for: session), ["dummy", "arc"])
    }

    /// A fetch that fails keeps what was cached and is retried at once, not after the freshness window.
    func testAFailedFetchKeepsTheCachedNamesAndRetries() async {
        let api = FakeSkillApi()
        await api.queue(.success(listing(["dummy"])))
        await api.queue(.failure(.transport("offline")))
        await api.queue(.success(listing(["arc"])))
        let clock = Clock()
        let store = SkillStore(api: api, now: { clock.read() })

        await store.load(session)
        clock.current.addTimeInterval(120)
        await store.load(session)
        XCTAssertEqual(store.names(for: session), ["dummy"])

        await store.load(session)
        XCTAssertEqual(store.names(for: session), ["arc"])
    }

    func testOverlappingLoadsOfOneContextAskOnce() async {
        let api = FakeSkillApi(delay: .milliseconds(100))
        await api.queue(.success(listing(["dummy"])))
        let store = SkillStore(api: api)

        let first = Task { await store.load(session) }
        let second = Task { await store.load(session) }
        await first.value
        await second.value

        let asked = await api.asked.count
        XCTAssertEqual(asked, 1)
    }

    func testNoListingYieldsNoNames() async {
        let store = SkillStore(api: FakeSkillApi())
        await store.load(session)
        XCTAssertEqual(store.names(for: session), [])
    }
}

final class SkillsWireTests: XCTestCase {
    override func tearDown() {
        PaiStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() throws -> PaiApiClient {
        let factory = try PaiRequestFactory(baseURL: "https://pai.example.com", tokenProvider: { "jwt" })
        return PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
    }

    private func stub(_ json: String) {
        PaiStubURLProtocol.stub = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
    }

    func testListingDecodesAndASessionIsAskedForById() async throws {
        stub(
            #"{"skills":[{"name":"anthropic-skills:docx","description":""},{"name":"dummy","description":"x"}],"updated_at":"2026-10-22T10:00:00.123456+00:00"}"#
        )
        let result = try await makeClient().getSkills(for: .session("abc"))

        let url = try XCTUnwrap(PaiStubURLProtocol.capturedRequest?.url)
        XCTAssertEqual(url.path, "/api/skills")
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "session_id", value: "abc")])
        XCTAssertEqual(result.skills.map(\.name), ["anthropic-skills:docx", "dummy"])
        XCTAssertEqual(result.updatedAt, "2026-10-22T10:00:00.123456+00:00")
    }

    func testANewSessionIsAskedForByItsSettingsAndNullTimestampDecodes() async throws {
        stub(#"{"skills":[],"updated_at":null}"#)
        let result = try await makeClient().getSkills(
            for: .newSession(agent: "vm", sessionType: "custom", workingDir: "/home/x"))

        let url = try XCTUnwrap(PaiStubURLProtocol.capturedRequest?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(
            items,
            [
                URLQueryItem(name: "agent", value: "vm"), URLQueryItem(name: "session_type", value: "custom"),
                URLQueryItem(name: "working_dir", value: "/home/x"),
            ])
        XCTAssertNil(result.updatedAt)
    }
}
