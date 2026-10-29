import XCTest

@testable import PAIKit

/// Which banner a waiting session gets, and what pressing its buttons does to the session list.
@MainActor
final class BlockerBannerTests: XCTestCase {

    private func blocker(_ kind: BlockerKind, options: [BlockerOption] = []) -> Blocker {
        Blocker(kind: kind, question: "Q?", options: options)
    }

    private let yes = BlockerOption(key: "1", label: "Yes")

    // MARK: - Content

    func testNothingShowsForASessionThatIsNotWaiting() {
        for state: SessionState? in [nil, .starting, .ready, .closed] {
            XCTAssertNil(
                BlockerBannerContent.make(state: state, blocker: blocker(.permissionPrompt)),
                "\(String(describing: state))")
        }
    }

    func testBlockedWithoutAPayloadShowsNothingButAttentionSaysSo() {
        XCTAssertNil(BlockerBannerContent.make(state: .blocked, blocker: nil))
        XCTAssertEqual(
            BlockerBannerContent.make(state: .attention, blocker: nil),
            .terminalOnly(message: BlockerBannerContent.attentionMessage))
    }

    func testARecognisedPromptCarriesItsOptionsAndTheStatesSeverity() {
        let prompt = blocker(.permissionPrompt, options: [yes])
        XCTAssertEqual(
            BlockerBannerContent.make(state: .blocked, blocker: prompt),
            .question(text: "Q?", options: [yes], severity: .warning))
        XCTAssertEqual(
            BlockerBannerContent.make(state: .attention, blocker: prompt),
            .question(text: "Q?", options: [yes], severity: .error))
    }

    /// A kind added to the backend later still shows its question and buttons, as on the web;
    /// only the backend's own `unknown` is sent to the terminal.
    func testAnUnrecognisedKindIsStillAPrompt() {
        XCTAssertEqual(
            BlockerBannerContent.make(state: .blocked, blocker: blocker(.unrecognized("future"), options: [yes])),
            .question(text: "Q?", options: [yes], severity: .warning))
        XCTAssertEqual(
            BlockerBannerContent.make(state: .blocked, blocker: blocker(.unknown)),
            .terminalOnly(message: BlockerBannerContent.unexpectedWaitMessage))
    }

    func testTheKindsThatAreNotAnsweredWithButtonsNeverOfferThem() {
        XCTAssertEqual(
            BlockerBannerContent.make(state: .blocked, blocker: blocker(.loginRequired, options: [yes])), .signInWait)
        XCTAssertEqual(
            BlockerBannerContent.make(state: .blocked, blocker: blocker(.trustPromptConfirmed, options: [yes])),
            .autoConfirmed(text: "Q?"))
        XCTAssertEqual(
            BlockerBannerContent.make(state: .attention, blocker: blocker(.notRegistered, options: [yes])),
            .unreachable(paneText: "Q?"))
    }

    /// The fixture corpus carries the wire shape of `not_registered`; it must reach the repair
    /// banner rather than decode as an unrecognised prompt.
    func testTheWireNotRegisteredBlockerReachesTheRepairBanner() throws {
        let session = try JSONDecoder().decode(
            Session.self, from: Data(PaiFixtures.sessionAttentionNotRegistered.utf8))
        guard case .unreachable = BlockerBannerContent.make(state: session.state, blocker: session.blocker) else {
            return XCTFail("\(String(describing: session.blocker))")
        }
    }

    // MARK: - Store

    private func makeStore(
        session: Session, api: FakeBlockerBannerApi
    ) async -> (BlockerBannerStore, SessionListStore, ToastCenter) {
        let listApi = FakeSessionListApi()
        await listApi.setGetSessionsResult { _ in .success(SessionsPage(sessions: [session], nextCursor: nil)) }
        let list = SessionListStore(api: listApi)
        await list.loadInitialSessions()
        return (BlockerBannerStore(sessionId: session.id, sessionList: list, api: api), list, ToastCenter())
    }

    func testAnswerSendsTheOptionKey() async {
        let api = FakeBlockerBannerApi()
        let (store, _, toasts) = await makeStore(session: SessionFixture.make(state: .blocked), api: api)

        await store.answer("2", toasts: toasts)

        let calls = await api.answerCalls
        XCTAssertEqual(calls.map(\.key), ["2"])
        XCTAssertEqual(calls.map(\.sessionId), ["s1"])
        XCTAssertNil(store.answeringKey)
        XCTAssertTrue(toasts.toasts.isEmpty)
    }

    func testAFailedAnswerToastsTheServersReasonAndFreesTheButtons() async {
        let api = FakeBlockerBannerApi()
        await api.setAnswerResult(.failure(.detail("No blocker pending for this session", statusCode: 409)))
        let (store, _, toasts) = await makeStore(session: SessionFixture.make(state: .blocked), api: api)

        await store.answer("1", toasts: toasts)

        XCTAssertEqual(toasts.toasts.map(\.text), ["No blocker pending for this session"])
        XCTAssertEqual(toasts.toasts.map(\.kind), [.error])
        XCTAssertNil(store.answeringKey)
    }

    func testAnswerIsRefusedWhileAnotherIsInFlight() async {
        let api = FakeBlockerBannerApi()
        await api.holdAnswers()
        let (store, _, toasts) = await makeStore(session: SessionFixture.make(state: .blocked), api: api)

        let first = Task { await store.answer("1", toasts: toasts) }
        while await api.answerCalls.isEmpty { await Task.yield() }
        XCTAssertEqual(store.answeringKey, "1")
        await store.answer("2", toasts: toasts)
        await api.releaseAnswers()
        await first.value

        let keys = await api.answerCalls.map(\.key)
        XCTAssertEqual(keys, ["1"])
    }

    func testRestartClosesThenResumesAndAdoptsTheLaunchedRow() async {
        let api = FakeBlockerBannerApi()
        let launched = SessionFixture.make(state: .starting, displayState: .starting)
        await api.setResumeResult(.success(ResumeResponse(status: .resumed, detail: nil, session: launched)))
        let stuck = SessionFixture.make(
            state: .attention, blocker: blocker(.notRegistered), displayState: .error)
        let (store, list, toasts) = await makeStore(session: stuck, api: api)

        await store.restart(toasts: toasts)

        let order = await api.restartCalls
        XCTAssertEqual(order, ["close:s1", "resume:s1"])
        XCTAssertEqual(list.session(withId: "s1")?.state, .starting)
        XCTAssertNil(list.session(withId: "s1")?.blocker)
        XCTAssertFalse(store.isRestarting)
        XCTAssertTrue(toasts.toasts.isEmpty)
    }

    /// A close that fails still leaves the relaunch worth attempting, as on the web.
    func testRestartResumesEvenWhenTheCloseFails() async {
        let api = FakeBlockerBannerApi()
        await api.setCloseResult(.failure(.transport("offline")))
        let stuck = SessionFixture.make(state: .attention, blocker: blocker(.notRegistered))
        let (store, _, toasts) = await makeStore(session: stuck, api: api)

        await store.restart(toasts: toasts)

        let order = await api.restartCalls
        XCTAssertEqual(order, ["close:s1", "resume:s1"])
    }

    func testARefusedRelaunchToastsAndLeavesTheRowClosed() async {
        let api = FakeBlockerBannerApi()
        await api.setResumeResult(
            .success(ResumeResponse(status: .refused, detail: "Machine offline", session: nil)))
        let stuck = SessionFixture.make(state: .attention, blocker: blocker(.notRegistered), displayState: .error)
        let (store, list, toasts) = await makeStore(session: stuck, api: api)

        await store.restart(toasts: toasts)

        XCTAssertEqual(toasts.toasts.map(\.text), ["Machine offline"])
        XCTAssertEqual(list.session(withId: "s1")?.state, .closed)
        XCTAssertEqual(list.session(withId: "s1")?.displayState, .closed)
        XCTAssertFalse(store.isRestarting)
    }

    func testAFailedResumeRequestLeavesTheRowClosed() async {
        let api = FakeBlockerBannerApi()
        await api.setResumeResult(.failure(.detail("Agent not connected", statusCode: 503)))
        let stuck = SessionFixture.make(state: .attention, blocker: blocker(.notRegistered))
        let (store, list, toasts) = await makeStore(session: stuck, api: api)

        await store.restart(toasts: toasts)

        XCTAssertEqual(toasts.toasts.map(\.text), ["Agent not connected"])
        XCTAssertEqual(list.session(withId: "s1")?.state, .closed)
    }
}

actor FakeBlockerBannerApi: BlockerBannerApiClient {
    private(set) var answerCalls: [(sessionId: String, key: String)] = []
    /// `close:<id>` / `resume:<id>` in the order they arrived.
    private(set) var restartCalls: [String] = []
    private var answerResult: Result<AnswerBlockerResponse, PaiError> = .success(
        AnswerBlockerResponse(status: .ok, detail: nil))
    private var closeResult: Result<CloseResponse, PaiError> = .success(CloseResponse(status: .closed, detail: nil))
    private var resumeResult: Result<ResumeResponse, PaiError> = .success(
        ResumeResponse(status: .resumed, detail: nil, session: nil))
    private var holdFirstAnswer = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func setAnswerResult(_ result: Result<AnswerBlockerResponse, PaiError>) { answerResult = result }
    func setCloseResult(_ result: Result<CloseResponse, PaiError>) { closeResult = result }
    func setResumeResult(_ result: Result<ResumeResponse, PaiError>) { resumeResult = result }
    /// Suspends only the next answer, so a second one that wrongly gets through returns at once
    /// and shows up in `answerCalls` instead of hanging the test.
    func holdAnswers() { holdFirstAnswer = true }
    func releaseAnswers() {
        waiting.forEach { $0.resume() }
        waiting = []
    }

    func answerBlocker(sessionId: String, key: String) async throws -> AnswerBlockerResponse {
        answerCalls.append((sessionId, key))
        if holdFirstAnswer {
            holdFirstAnswer = false
            await withCheckedContinuation { waiting.append($0) }
        }
        return try answerResult.get()
    }

    func closeSession(sessionId: String) async throws -> CloseResponse {
        restartCalls.append("close:\(sessionId)")
        return try closeResult.get()
    }

    func resumeSession(sessionId: String) async throws -> ResumeResponse {
        restartCalls.append("resume:\(sessionId)")
        return try resumeResult.get()
    }
}
