import XCTest

@testable import PAIKit

/// Everything the fake search was asked, and the means to hold or fail its answers.
@MainActor
private final class FakeMeaningSearch {
    struct Call: Equatable {
        let query: String
        let window: TimeBounds?
    }

    private(set) var calls: [Call] = []
    var answer: @MainActor (String) -> Result<[NoteSemanticHit], PaiError> = { _ in .success([]) }
    /// Queries whose answer is held until `release(_:)`.
    private var held: [String: CheckedContinuation<Void, Never>] = [:]
    private var holding: Set<String> = []

    func hold(_ query: String) { holding.insert(query) }

    func release(_ query: String) {
        holding.remove(query)
        held.removeValue(forKey: query)?.resume()
    }

    func search(_ query: String, _ window: TimeBounds?) async throws -> [NoteSemanticHit] {
        calls.append(Call(query: query, window: window))
        if holding.contains(query) {
            await withCheckedContinuation { held[query] = $0 }
        }
        return try answer(query).get()
    }
}

@MainActor
final class NoteMeaningSearchStoreTests: XCTestCase {

    private static let debounce: UInt64 = 20_000_000
    private nonisolated static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore(_ fake: FakeMeaningSearch) -> NoteMeaningSearchStore {
        NoteMeaningSearchStore(debounceNanos: Self.debounce, now: { Self.fixedNow }) { query, window in
            try await fake.search(query, window)
        }
    }

    private func wait(_ what: String, until condition: () -> Bool) async {
        let deadline = ContinuousClock().now + .seconds(5)
        while !condition(), ContinuousClock().now < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(condition(), what)
    }

    /// A burst of typing is one request, for the final text.
    func testTypingInABurstSendsOneRequestForTheLastText() async {
        let fake = FakeMeaningSearch()
        let store = makeStore(fake)

        store.update(query: "k", window: nil)
        store.update(query: "ku", window: nil)
        store.update(query: "kub", window: nil)

        await wait("the search runs") { store.phase == .ready }
        XCTAssertEqual(fake.calls.map(\.query), ["kub"])
    }

    func testThePhaseIsSearchingFromTheFirstKeystrokeOn() {
        let store = makeStore(FakeMeaningSearch())
        store.update(query: "k", window: nil)
        XCTAssertEqual(store.phase, .searching)
    }

    func testTheTieredHitsLandInTheBackendsOrder() async {
        let fake = FakeMeaningSearch()
        fake.answer = { _ in
            .success([NoteSemanticHit(noteId: "b", tier: 1), NoteSemanticHit(noteId: "a", tier: 2)])
        }
        let store = makeStore(fake)

        store.update(query: "kube", window: nil)
        await wait("hits land") { store.phase == .ready }

        XCTAssertEqual(store.hits.map(\.noteId), ["b", "a"])
    }

    /// A window picked for the same text is a discrete choice: it goes out at once, windowed,
    /// while a keystroke would still be waiting out the debounce (an hour here).
    func testAWindowChangeForTheSameTextSkipsTheDebounce() async {
        let fake = FakeMeaningSearch()
        let store = NoteMeaningSearchStore(debounceNanos: 3_600_000_000_000, now: { Self.fixedNow }) { query, window in
            try await fake.search(query, window)
        }
        store.update(query: "kube", window: nil)
        XCTAssertEqual(fake.calls, [], "the typed text is still debouncing")

        store.update(query: "kube", window: .preset(.last7Days))
        await wait("the windowed search goes out") { fake.calls.count == 1 }

        XCTAssertEqual(
            fake.calls.first?.window,
            TimeBounds(since: Self.fixedNow.addingTimeInterval(-7 * 86_400), until: Self.fixedNow))
    }

    /// Any 503 keeps the phone on the filter's matches: no hits, an `unavailable` phase.
    func testAnOutageEndsUnavailableWithNoHits() async {
        let fake = FakeMeaningSearch()
        fake.answer = { _ in .failure(.detail("semantic_unavailable", statusCode: 503)) }
        let store = makeStore(fake)

        store.update(query: "kube", window: nil)
        await wait("outage") { store.phase == .unavailable }

        XCTAssertEqual(store.hits, [])
    }

    func testAnotherFailureCarriesItsMessage() async {
        let fake = FakeMeaningSearch()
        fake.answer = { _ in .failure(.detail("boom", statusCode: 500)) }
        let store = makeStore(fake)

        store.update(query: "kube", window: nil)
        await wait("failure") { store.phase == .failed("boom") }
    }

    /// An answer for text that has since changed must not land.
    func testAStaleAnswerIsDropped() async {
        let fake = FakeMeaningSearch()
        fake.hold("first")
        fake.answer = { query in .success([NoteSemanticHit(noteId: query, tier: 1)]) }
        let store = makeStore(fake)

        store.update(query: "first", window: nil)
        await wait("first is out") { fake.calls.map(\.query) == ["first"] }
        store.update(query: "second", window: nil)
        await wait("second lands") { store.phase == .ready }
        fake.release("first")
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(store.hits.map(\.noteId), ["second"])
    }

    func testBlankTextEndsTheSearch() async {
        let fake = FakeMeaningSearch()
        fake.answer = { _ in .success([NoteSemanticHit(noteId: "a", tier: 1)]) }
        let store = makeStore(fake)
        store.update(query: "kube", window: nil)
        await wait("hits land") { store.phase == .ready }

        store.update(query: "  ", window: nil)

        XCTAssertEqual(store.phase, .idle)
        XCTAssertEqual(store.hits, [])
    }
}

final class SemanticUnavailableTests: XCTestCase {
    func testOnlyA503MeansSemanticSearchIsUnavailable() {
        XCTAssertTrue(PaiError.detail("semantic_unavailable", statusCode: 503).isSemanticUnavailable)
        XCTAssertTrue(PaiError.http(statusCode: 503, reason: "Service Unavailable").isSemanticUnavailable)
        XCTAssertFalse(PaiError.detail("x", statusCode: 500).isSemanticUnavailable)
        XCTAssertFalse(PaiError.detail("x", statusCode: 401).isSemanticUnavailable)
        XCTAssertFalse(PaiError.transport("offline").isSemanticUnavailable)
    }
}
