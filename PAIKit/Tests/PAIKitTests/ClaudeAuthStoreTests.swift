import XCTest
@testable import PAIKit

/// `ClaudeAuthPredicates` is the one authority the sign-in banner reads — a regression here is a
/// regression in every client that ports it, silently, since nothing else re-derives these
/// answers. See `ClaudeAuth`'s own doc comment for the outage a wrong predicate here caused once
/// already on the web.
final class ClaudeAuthPredicatesTests: XCTestCase {

    private func auth(
        known: Bool = true, loggedIn: Bool? = nil, health: CredentialHealth? = nil,
        refreshExpiresAt: Double? = nil, login: ClaudeLogin? = nil
    ) -> ClaudeAuth {
        ClaudeAuth(
            known: known, loggedIn: loggedIn, health: health, subscription: nil,
            accessExpiresAt: nil, refreshExpiresAt: refreshExpiresAt, login: login, lastError: nil,
            reportedAt: nil
        )
    }

    func testNeedsSignInRequiresKnownAndExplicitlyFalseLoggedIn() {
        XCTAssertFalse(ClaudeAuthPredicates.needsSignIn(auth(known: false, loggedIn: false)))
        XCTAssertFalse(ClaudeAuthPredicates.needsSignIn(auth(known: true, loggedIn: nil)))
        XCTAssertFalse(ClaudeAuthPredicates.needsSignIn(auth(known: true, loggedIn: true)))
        XCTAssertTrue(ClaudeAuthPredicates.needsSignIn(auth(known: true, loggedIn: false)))
    }

    /// The outage this guards against: a credential that looks healthy by every other measure
    /// (both expiries far out) while Anthropic refuses it — `health == .rejected` must still read
    /// as "needs sign-in", never as merely a cosmetic detail.
    func testIsRejectedRequiresNeedingSignInAsWellAsRejectedHealth() {
        XCTAssertFalse(
            ClaudeAuthPredicates.isRejected(auth(known: true, loggedIn: false, health: .ok)))
        XCTAssertFalse(
            // Healthy per `loggedIn`, so `rejected` health here must not flip the verdict —
            // `loggedIn` is the one authority.
            ClaudeAuthPredicates.isRejected(auth(known: true, loggedIn: true, health: .rejected)))
        XCTAssertTrue(
            ClaudeAuthPredicates.isRejected(auth(known: true, loggedIn: false, health: .rejected)))
    }

    func testExpiresWithinWarningIsStrictlyLessThanTheWindow() {
        let now = 1_800_000_000_000.0
        let exactlyAtWindow = auth(refreshExpiresAt: now + ClaudeAuthPredicates.expiryWarningMs)
        let oneMsInsideWindow = auth(refreshExpiresAt: now + ClaudeAuthPredicates.expiryWarningMs - 1)

        XCTAssertFalse(ClaudeAuthPredicates.expiresWithinWarning(exactlyAtWindow, now: now))
        XCTAssertTrue(ClaudeAuthPredicates.expiresWithinWarning(oneMsInsideWindow, now: now))
    }

    func testExpiresWithinWarningIsFalseWithoutAReportedExpiry() {
        XCTAssertFalse(ClaudeAuthPredicates.expiresWithinWarning(auth(refreshExpiresAt: nil), now: 0))
    }

    func testPollIntervalIsActiveWhileSignedOutOrMidLoginOnly() {
        XCTAssertEqual(
            ClaudeAuthPredicates.pollInterval(auth(known: false)), ClaudeAuthPredicates.idlePollNanos)
        XCTAssertEqual(
            ClaudeAuthPredicates.pollInterval(auth(known: true, loggedIn: false)),
            ClaudeAuthPredicates.activePollNanos)
        XCTAssertEqual(
            ClaudeAuthPredicates.pollInterval(auth(known: true, loggedIn: true)),
            ClaudeAuthPredicates.idlePollNanos)
        let midLogin = ClaudeLogin(id: "l1", url: "https://example.com", state: .awaitingCode, startedAt: 0)
        XCTAssertEqual(
            ClaudeAuthPredicates.pollInterval(auth(known: true, loggedIn: true, login: midLogin)),
            ClaudeAuthPredicates.activePollNanos)
    }

    func testFormatTimeUntilBoundaries() {
        XCTAssertEqual(ClaudeAuthPredicates.formatTimeUntil(0), "now")
        XCTAssertEqual(ClaudeAuthPredicates.formatTimeUntil(-1), "now")
        XCTAssertEqual(ClaudeAuthPredicates.formatTimeUntil(3_599_999), "under an hour")
        XCTAssertEqual(ClaudeAuthPredicates.formatTimeUntil(3_600_000), "1 hour")
        XCTAssertEqual(ClaudeAuthPredicates.formatTimeUntil(2 * 3_600_000), "2 hours")
        XCTAssertEqual(ClaudeAuthPredicates.formatTimeUntil(48 * 3_600_000), "2 days")
    }

    /// The bug this guards: the button lived only in the expiring severity's view code, and the
    /// link + code field it produces lived only in the signed-out severity's — mutually exclusive,
    /// so a real sign-in ran on the VM with no way to ever show it. `actionState` is what a view
    /// now reads instead of re-deriving this itself, under every severity alike.
    func testActionStateShowsControlsOnceALoginExistsRegardlessOfSeverity() {
        let login = ClaudeLogin(id: "l1", url: "https://claude.ai/oauth/authorize", state: .awaitingCode, startedAt: 0)
        let auth = ClaudeAuth(
            known: true, loggedIn: true, subscription: nil, accessExpiresAt: nil,
            refreshExpiresAt: nil, login: login, lastError: nil, reportedAt: nil
        )

        let state = ClaudeAuthPredicates.actionState(auth: auth, busy: false, linkExpired: false)

        guard case .controls(let shown, let verifying, let busy) = state else {
            return XCTFail("expected .controls, got \(state)")
        }
        XCTAssertEqual(shown.url, "https://claude.ai/oauth/authorize")
        XCTAssertFalse(verifying)
        XCTAssertFalse(busy)
    }

    func testActionStateShowsTheButtonWithNoLoginAndNotBusy() {
        let auth = ClaudeAuth(
            known: true, loggedIn: true, subscription: nil, accessExpiresAt: nil,
            refreshExpiresAt: nil, login: nil, lastError: nil, reportedAt: nil
        )
        XCTAssertEqual(
            ClaudeAuthPredicates.actionState(auth: auth, busy: false, linkExpired: false),
            .signIn(linkExpired: false))
        XCTAssertEqual(
            ClaudeAuthPredicates.actionState(auth: auth, busy: false, linkExpired: true),
            .signIn(linkExpired: true))
    }

    func testActionStateShowsStartingWhileBusyWithNoLoginYet() {
        let auth = ClaudeAuth(
            known: true, loggedIn: true, subscription: nil, accessExpiresAt: nil,
            refreshExpiresAt: nil, login: nil, lastError: nil, reportedAt: nil
        )
        XCTAssertEqual(ClaudeAuthPredicates.actionState(auth: auth, busy: true, linkExpired: false), .starting)
    }

    /// The other half of the fix: a login attempt disappearing must not read as a timeout unless
    /// it has actually run out the clock — a success, a deliberate cancel, or a stale poll racing
    /// the one that just created it all end well under the deadline.
    func testLoginLikelyExpiredOnlyOnceTheDeadlineHasActuallyPassed() {
        let started = ClaudeLogin(id: "l1", url: "https://example.com", state: .awaitingCode, startedAt: 1_000_000)
        XCTAssertFalse(
            ClaudeAuthPredicates.loginLikelyExpired(previous: started, now: 1_000_000 + 5_000))
        XCTAssertTrue(
            ClaudeAuthPredicates.loginLikelyExpired(
                previous: started, now: 1_000_000 + ClaudeAuthPredicates.loginTimeoutMs))
    }
}

@MainActor
final class ClaudeAuthStoreTests: XCTestCase {

    private func auth(loggedIn: Bool?, login: ClaudeLogin? = nil) -> ClaudeAuth {
        ClaudeAuth(
            known: true, loggedIn: loggedIn, subscription: nil, accessExpiresAt: nil,
            refreshExpiresAt: nil, login: login, lastError: nil, reportedAt: nil
        )
    }

    /// A stale snapshot beats none — a poll tick that fails leaves `auth` exactly as it was, the
    /// same trade-off `MachineStore.refresh()` makes, so a transient blip never flashes a
    /// sign-in alarm at someone who is actually signed in fine.
    func testFailedRefreshKeepsThePreviousSnapshot() async {
        let api = FakeClaudeAuthApi()
        await api.setGetResult(.success(auth(loggedIn: true)))
        let store = ClaudeAuthStore(api: api)
        await store.refresh()
        XCTAssertEqual(store.auth.loggedIn, true)

        await api.setGetResult(.failure(.transport("offline")))
        await store.refresh()

        XCTAssertEqual(store.auth.loggedIn, true)
    }

    /// The attempt on screen can be replaced between opening the link and pasting the code —
    /// submitting against a stale id must fail locally, without ever reaching the server.
    func testSubmitCodeRejectsAStaleLoginIdWithoutCallingTheServer() async {
        let api = FakeClaudeAuthApi()
        let live = ClaudeLogin(id: "current", url: "https://example.com", state: .awaitingCode, startedAt: 0)
        await api.setGetResult(.success(auth(loggedIn: false, login: live)))
        let store = ClaudeAuthStore(api: api)
        await store.refresh()

        let result = await store.submitCode(loginId: "stale", code: "123456")

        XCTAssertFalse(result)
        XCTAssertNotNil(store.codeError)
        let calls = await api.submitCodeCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testSubmitCodeAppliesTheServerResponseWhenTheIdMatches() async {
        let api = FakeClaudeAuthApi()
        let live = ClaudeLogin(id: "current", url: "https://example.com", state: .verifying, startedAt: 0)
        await api.setGetResult(.success(auth(loggedIn: false, login: live)))
        let store = ClaudeAuthStore(api: api)
        await store.refresh()

        await api.setSubmitCodeResult(
            .success(
                ClaudeLoginCodeResponse(
                    known: true, loggedIn: true, subscription: "max", accessExpiresAt: nil,
                    refreshExpiresAt: nil, login: nil, lastError: nil, reportedAt: nil, ok: true, error: nil
                )))

        let result = await store.submitCode(loginId: "current", code: "123456")

        XCTAssertTrue(result)
        XCTAssertEqual(store.auth.loggedIn, true)
        XCTAssertNil(store.codeError)
    }
}

extension FakeClaudeAuthApi {
    func setGetResult(_ result: Result<ClaudeAuth, PaiError>) {
        self.getResult = result
    }

    func setSubmitCodeResult(_ result: Result<ClaudeLoginCodeResponse, PaiError>) {
        self.submitCodeResult = result
    }
}
