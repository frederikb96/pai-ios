import Foundation
import Observation

/// What the banner above a transcript says about a session that is waiting on its user. Swift
/// port of the branching in `pai-cloud/web/src/components/BlockerBanner.tsx`, kept out of the view
/// so every branch is provable on Linux.
public enum BlockerBannerContent: Equatable, Sendable {
    /// How loudly a banner is painted: amber while a recognised prompt waits, red when the
    /// session needs repair or the terminal.
    public enum Severity: Equatable, Sendable {
        case warning, error
    }

    /// The Claude sign-in is account-wide and answered in `ClaudeAuthBanner`; this session only
    /// says what it waits for, and relaunches by itself afterwards. No action here.
    case signInWait
    /// The agent answered a workspace-trust dialog on the reader's behalf. Calm status.
    case autoConfirmed(text: String)
    /// The pane is alive but unreachable (`BlockerKind.notRegistered`); only a restart repairs
    /// it, and the terminal shows `paneText`.
    case unreachable(paneText: String)
    /// A prompt only the reader can answer. `options` are buttons; empty means the terminal is
    /// the only way to answer (an MCP form, or a multi-part question).
    case question(text: String, options: [BlockerOption], severity: Severity)
    /// Something is waiting that the API cannot express; the terminal is the guaranteed fallback.
    case terminalOnly(message: String)

    static let unexpectedWaitMessage = "Something unexpected is waiting — open the terminal to see what Claude needs."
    static let attentionMessage = "Something needs you — open the terminal to handle it."

    /// `nil` when nothing is waiting. `attention` with no blocker payload still says so, and
    /// `blocked` without a payload says nothing, exactly as the web does.
    public static func make(state: SessionState?, blocker: Blocker?) -> BlockerBannerContent? {
        guard state == .blocked || state == .attention else { return nil }
        guard let blocker else { return state == .attention ? .terminalOnly(message: attentionMessage) : nil }
        switch blocker.kind {
        case .loginRequired:
            return .signInWait
        case .trustPromptConfirmed:
            return .autoConfirmed(text: blocker.question)
        case .notRegistered:
            return .unreachable(paneText: blocker.question)
        case .unknown:
            return .terminalOnly(message: unexpectedWaitMessage)
        case .trustPrompt, .permissionPrompt, .choicePrompt, .unrecognized:
            return .question(
                text: blocker.question, options: blocker.options, severity: state == .blocked ? .warning : .error)
        }
    }
}

/// The narrow slice of `PaiApiClient` the blocker banner needs.
public protocol BlockerBannerApiClient: Sendable {
    func answerBlocker(sessionId: String, key: String) async throws -> AnswerBlockerResponse
    func closeSession(sessionId: String) async throws -> CloseResponse
    func resumeSession(sessionId: String) async throws -> ResumeResponse
}

extension PaiApiClient: BlockerBannerApiClient {}

/// The two things the banner can do for a session: press one of the prompt's options, and
/// restart a session whose pane PAI cannot reach. Scoped to one session and built per screen.
/// A failure of either reaches the reader as a toast, since the banner stays where it was.
@MainActor
@Observable
public final class BlockerBannerStore {
    /// The option whose answer is in flight. Every button is disabled meanwhile: one answer
    /// types a key into the pane, and a second would land on whatever dialog follows.
    public private(set) var answeringKey: String?
    public private(set) var isRestarting = false

    public let sessionId: String
    private let sessionList: SessionListStore
    private let api: BlockerBannerApiClient

    public init(sessionId: String, sessionList: SessionListStore, api: BlockerBannerApiClient) {
        self.sessionId = sessionId
        self.sessionList = sessionList
        self.api = api
    }

    /// Whether a press has to be refused because another is still running.
    public var isBusy: Bool { answeringKey != nil || isRestarting }

    /// Sends `key` into the session's pane. The session's `state` and `blocker` are corrected by
    /// the status stream afterwards, so nothing is written to the list here.
    public func answer(_ key: String, toasts: ToastCenter) async {
        guard !isBusy else { return }
        answeringKey = key
        defer { answeringKey = nil }
        do {
            let result = try await api.answerBlocker(sessionId: sessionId, key: key)
            if result.status == .error {
                toasts.show(result.detail ?? "Failed to send answer", kind: .error)
            }
        } catch {
            toasts.show((error as? PaiError)?.userMessage ?? "Failed to send answer", kind: .error)
        }
    }

    /// Stops the session's process and launches it again, as the web's `restartSession` does. The
    /// row reads `starting` at once, so the banner leaves and the reader cannot restart twice; a
    /// failed relaunch puts it back to `closed`, where the composer offers Resume. A close that
    /// did not take still leaves the relaunch worth trying, which reports its own failure.
    public func restart(toasts: ToastCenter) async {
        guard !isBusy else { return }
        isRestarting = true
        defer { isRestarting = false }
        setRowState(.starting, displayState: .starting)
        _ = try? await api.closeSession(sessionId: sessionId)
        let failure: String?
        do {
            let result = try await api.resumeSession(sessionId: sessionId)
            if result.status == .refused {
                failure = result.detail ?? "This session could not be resumed"
            } else {
                failure = nil
                if let session = result.session { sessionList.replaceSession(session) }
            }
        } catch {
            failure = (error as? PaiError)?.userMessage ?? "Could not resume this session"
        }
        if let failure {
            toasts.show(failure, kind: .error)
            setRowState(.closed, displayState: .closed)
        }
    }

    private func setRowState(_ state: SessionState, displayState: DisplayState) {
        guard let session = sessionList.session(withId: sessionId) else { return }
        sessionList.replaceSession(
            session.withLiveStatus(
                state: state, blocker: nil, turnState: session.turnState, displayState: displayState,
                activityCounts: session.activityCounts, secretGrantable: session.secretGrantable,
                secretPrompt: session.secretPrompt, liveModel: session.liveModel, model: session.model,
                pendingModel: session.pendingModel))
    }
}
