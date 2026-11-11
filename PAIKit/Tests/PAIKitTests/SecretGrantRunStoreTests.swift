import XCTest

@testable import PAIKit

/// A grant runs after its sheet closed: what it hands over, what the person is told wherever they
/// are, and how a failure finds its way back to a sheet.
@MainActor
final class SecretGrantRunStoreTests: XCTestCase {

    /// Answers each call with the next queued result and records what it was asked.
    private actor Server {
        struct Call: Equatable {
            let sessionId: String
            let passphrase: String
            let ttlSeconds: Int
            let scope: SecretGrantScope
        }
        private(set) var calls: [Call] = []
        private var answers: [Result<SecretGrantResult, PaiError>]
        private var gate: CheckedContinuation<Void, Never>?
        private var held = false

        init(_ answers: [Result<SecretGrantResult, PaiError>]) { self.answers = answers }

        func holdNext() { held = true }
        func release() {
            gate?.resume()
            gate = nil
            held = false
        }

        func answer(_ call: Call) async throws -> SecretGrantResult {
            calls.append(call)
            if held { await withCheckedContinuation { gate = $0 } }
            return try answers.removeFirst().get()
        }
    }

    private func makeStore(_ server: Server) -> SecretGrantRunStore {
        SecretGrantRunStore { sessionId, passphrase, ttl, scope in
            try await server.answer(.init(sessionId: sessionId, passphrase: passphrase, ttlSeconds: ttl, scope: scope))
        }
    }

    private func eventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock().now + timeout
        while !condition() {
            if ContinuousClock().now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func testSuccessShowsASuccessToastAndLeavesNothingToReopen() async {
        let server = Server([.success(.granted(expiresAt: "not-a-date", names: ["GITHUB_TOKEN"]))])
        let store = makeStore(server)
        let toasts = ToastCenter()

        store.start(sessionId: "s1", passphrase: "pw", ttlSeconds: 3600, scope: .requested, toasts: toasts)

        let shown = await eventually { !toasts.toasts.isEmpty }
        XCTAssertTrue(shown)
        XCTAssertEqual(toasts.toasts.first?.kind, .success)
        XCTAssertTrue(toasts.toasts.first?.text.contains("GITHUB_TOKEN") ?? false)
        XCTAssertNil(store.takeFailure(sessionId: "s1"))
        XCTAssertTrue(store.inFlight.isEmpty)
        let calls = await server.calls
        XCTAssertEqual(calls, [.init(sessionId: "s1", passphrase: "pw", ttlSeconds: 3600, scope: .requested)])
    }

    func testAHeldGrantSaysItWaitsForTheSession() async {
        let store = makeStore(Server([.success(.pending)]))
        let toasts = ToastCenter()

        store.start(sessionId: "s1", passphrase: "pw", ttlSeconds: 3600, scope: .all, toasts: toasts)

        let shown = await eventually { !toasts.toasts.isEmpty }
        XCTAssertTrue(shown)
        XCTAssertEqual(toasts.toasts.first?.kind, .success)
        XCTAssertTrue(toasts.toasts.first?.text.contains("ready") ?? false)
    }

    func testAFailureWithNoComposerOnScreenIsAnErrorToastThatOpensTheSession() async {
        let store = makeStore(Server([.success(.wrongPassphrase)]))
        var opened: [String] = []
        store.openSession = { opened.append($0) }
        let toasts = ToastCenter()

        store.start(sessionId: "s1", passphrase: "pw", ttlSeconds: 3600, scope: .requested, toasts: toasts)

        let shown = await eventually { !toasts.toasts.isEmpty }
        XCTAssertTrue(shown)
        XCTAssertEqual(toasts.toasts.first?.kind, .error)
        toasts.toasts.first?.action?.handler()
        XCTAssertEqual(opened, ["s1"])
        XCTAssertEqual(store.takeFailure(sessionId: "s1"), "Wrong passphrase.")
        XCTAssertNil(store.takeFailure(sessionId: "s1"), "a failure is shown once")
    }

    func testAFailureWhileTheSessionsComposerIsOnScreenIsLeftToItsSheetWithoutAToast() async {
        let store = makeStore(Server([.failure(.transport("offline")), .success(.wrongPassphrase)]))
        let toasts = ToastCenter()
        store.composerAppeared(sessionId: "s1")

        store.start(sessionId: "s1", passphrase: "pw", ttlSeconds: 3600, scope: .requested, toasts: toasts)
        let failed = await eventually { store.failures["s1"] != nil }

        XCTAssertTrue(failed)
        XCTAssertTrue(toasts.toasts.isEmpty)

        _ = store.takeFailure(sessionId: "s1")
        store.composerDisappeared(sessionId: "s1")
        store.start(sessionId: "s1", passphrase: "pw", ttlSeconds: 3600, scope: .requested, toasts: toasts)
        let toasted = await eventually { !toasts.toasts.isEmpty }
        XCTAssertTrue(toasted, "once the composer left, the failure is told by a toast")
    }

    func testASecondRequestForASessionStillRunningIsIgnored() async {
        let server = Server([.success(.pending)])
        await server.holdNext()
        let store = makeStore(server)
        let toasts = ToastCenter()

        store.start(sessionId: "s1", passphrase: "first", ttlSeconds: 3600, scope: .all, toasts: toasts)
        let running = await eventually { store.inFlight == ["s1"] }
        XCTAssertTrue(running)
        store.start(sessionId: "s1", passphrase: "second", ttlSeconds: 3600, scope: .all, toasts: toasts)
        await server.release()

        let done = await eventually { store.inFlight.isEmpty }
        XCTAssertTrue(done)
        let calls = await server.calls
        XCTAssertEqual(calls.map(\.passphrase), ["first"])
    }

    func testEveryRefusalReadsAsAFailureCarryingItsOwnSentence() {
        let results: [SecretGrantResult] = [
            .wrongPassphrase, .sessionUnavailable, .nothingRequested, .timedOut,
            .notAuthorized(message: "a"), .rateLimited(message: "b"), .invalidRequest(message: "c"),
        ]
        let messages = results.map { result -> String in
            guard case let .failure(message) = SecretGrantOutcome(result) else {
                XCTFail("\(result) is not a failure")
                return ""
            }
            return message
        }
        XCTAssertEqual(Set(messages).count, results.count, "\(messages)")
    }
}
