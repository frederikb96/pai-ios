import XCTest

@testable import PAIKit

/// Covers `locate` and the first landing of a transcript opened at a deep link — the path a
/// tapped notification takes into a session this process has not loaded yet.
///
/// Every method is `async` for the Linux test-discovery reason `TranscriptStoreTests` documents.
@MainActor
final class TranscriptLocateTests: XCTestCase {

    /// Stands in for `GET /api/session/{id}/messages?around_id=` over one session whose messages
    /// are `ids`, split the way the backend splits it: `ceil(limit/2)` at-or-before the target,
    /// `floor(limit/2)` after. `notFoundResponses` answers that many requests with a 404 first, the
    /// way a target that has not been ingested yet does.
    @MainActor
    private final class FakeServer {
        let ids: [Int]
        var notFoundResponses: Int
        private(set) var requests: [Int] = []

        init(ids: [Int], notFoundResponses: Int = 0) {
            self.ids = ids
            self.notFoundResponses = notFoundResponses
        }

        func around(_ target: Int, limit: Int) async throws -> MessagesAroundResult {
            requests.append(target)
            if notFoundResponses > 0 {
                notFoundResponses -= 1
                return .notFound
            }
            guard ids.contains(target) else { return .notFound }
            let before = ids.filter { $0 <= target }.suffix((limit + 1) / 2)
            let after = ids.filter { $0 > target }.prefix(limit / 2)
            return .ok(messages: (before + after).map { Self.message(id: $0) })
        }

        static func message(id: Int) -> Message {
            Message(
                id: id, sessionId: "s1", type: .user, subtype: nil, outboxId: nil, timestamp: nil, content: "m\(id)",
                thinking: nil, toolCalls: nil, toolResult: nil, hookSummary: nil, tokens: nil, origin: nil,
                originMeta: nil, createdAt: nil)
        }
    }

    /// A session of 1000 messages with its 300-message tail bootstrapped — the state a transcript
    /// opened from a notification is in the moment `deepLinkLanding` runs.
    private func bootstrappedStore(server: FakeServer) -> TranscriptStore {
        let store = TranscriptStore()
        store.applyBootstrap(
            sessionId: "s1", entries: server.ids.suffix(TranscriptStore.tailLimit).map { FakeServer.message(id: $0) },
            requestedLimit: TranscriptStore.tailLimit)
        return store
    }

    // MARK: - The first landing of a deep-linked open

    /// A notification for a message older than the tail must not open the session at its bottom
    /// and only then go looking for the target. The first landing has to be the linked message,
    /// already in the window — and the window has to know it is not at the tail, or live
    /// messages would be appended straight under a page from hours earlier.
    func testADeepLinkOlderThanTheTailLandsOnTheLinkedMessageFirst() async {
        let server = FakeServer(ids: Array(1...1000))
        let store = bootstrappedStore(server: server)

        let landing = await store.deepLinkLanding(for: 100, sessionId: "s1", fetchAround: server.around)

        XCTAssertEqual(landing, .deepLink(id: 100))
        XCTAssertTrue(store.isLoaded(100, sessionId: "s1"))
        XCTAssertFalse(
            store.isLoaded(1000, sessionId: "s1"), "a page this far off replaces the tail, never gaps onto it")
        XCTAssertTrue(store.window(for: "s1").hasNewer)
    }

    /// Most notifications point at something recent, which the tail already holds — that open
    /// must cost no extra round trip at all.
    func testADeepLinkInsideTheTailLandsWithoutFetchingAnything() async {
        let server = FakeServer(ids: Array(1...1000))
        let store = bootstrappedStore(server: server)

        let landing = await store.deepLinkLanding(for: 950, sessionId: "s1", fetchAround: server.around)

        XCTAssertEqual(landing, .deepLink(id: 950))
        XCTAssertEqual(server.requests, [])
    }

    /// A target that has not been ingested yet must not hold the open hostage to a retry ladder
    /// that can run for most of a minute: one attempt, then the open lands where an ordinary one
    /// would and the retries carry on from there.
    func testADeepLinkNotIngestedYetGivesTheOpenBackAfterOneAttempt() async {
        let server = FakeServer(ids: Array(1...1000), notFoundResponses: 1)
        let store = bootstrappedStore(server: server)

        let landing = await store.deepLinkLanding(for: 100, sessionId: "s1", fetchAround: server.around)

        XCTAssertNil(landing)
        XCTAssertEqual(server.requests, [100])
        XCTAssertTrue(store.isLoaded(1000, sessionId: "s1"), "a miss must leave the tail the open lands on intact")
    }

    // MARK: - locate

    /// A page that reaches the tail is folded into it, keeping the reader's context and the
    /// window's claim to be at the live edge — replacing it here would throw away the very rows
    /// the page connects to.
    func testLocateMergesAPageThatReachesTheWindowAndStaysAtTheTail() async {
        let server = FakeServer(ids: Array(1...1000))
        let store = bootstrappedStore(server: server)

        let outcome = await store.locate(640, sessionId: "s1", fetchAround: server.around)

        XCTAssertEqual(outcome, .merged)
        XCTAssertEqual(store.messages["s1"]?.map(\.id), Array(566...1000))
        XCTAssertFalse(store.window(for: "s1").hasNewer)
    }

    /// The ladder is what separates "not ingested yet" from "gone" for a deep link — each 404 on
    /// it is waited out and asked again, not taken as the answer.
    func testLocateRetriesATargetAlongTheLadderUntilItArrives() async {
        let server = FakeServer(ids: Array(1...1000), notFoundResponses: 2)
        let store = bootstrappedStore(server: server)

        let outcome = await store.locate(
            100, sessionId: "s1", retryLadder: [.zero, .zero, .zero], fetchAround: server.around)

        XCTAssertEqual(outcome, .replaced)
        XCTAssertEqual(server.requests, [100, 100, 100])
    }
}
