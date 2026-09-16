import Foundation
import Observation

/// Everything `CallModeStore` needs that this package cannot provide itself. Reads the live take
/// through `currentLedger` rather than owning any pipeline state itself — `CallModeStore` never
/// mutates a ledger or drives a socket; it only decides, from the ledger's own committed segments
/// and gaps, when a "stop" boundary is ready to become a sent message.
public struct CallModeDependencies: Sendable {
    /// The `WaitForCommitPolicy` poll loop's own wait — instant in tests, real in production.
    /// Everything else this store waits on (a held `pendingSend`) is event-driven through
    /// `ledgerChanged()` rather than polled, so this is the only clock-shaped dependency needed.
    public var sleep: @Sendable (Duration) async -> Void
    public var currentLedger: @Sendable () -> TranscriptLedger
    /// Sends the assembled text as this session's next message — the existing send path
    /// (`postMessage`/`trackSend`), already responsible for its own failed-send handling
    /// (keeping the text recoverable, a retry affordance) once the text leaves this store.
    public var postMessage: @Sendable (_ text: String) async throws -> Void
    public var feedback: @Sendable (FeedbackEvent) -> Void

    public init(
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        currentLedger: @escaping @Sendable () -> TranscriptLedger,
        postMessage: @escaping @Sendable (_ text: String) async throws -> Void,
        feedback: @escaping @Sendable (FeedbackEvent) -> Void = { _ in }
    ) {
        self.sleep = sleep
        self.currentLedger = currentLedger
        self.postMessage = postMessage
        self.feedback = feedback
    }
}

/// Where call mode is in its own lifecycle. `listening` and `collecting` are the pair the design
/// moves between for the whole call; `entering` and `sending`/`pendingSend` are the transient
/// edges around them.
public enum CallModePhase: Sendable, Equatable {
    case idle
    /// Connecting the pipeline and the command channel — before call mode has anything to say
    /// about audio at all. `finishEntering(atOffset:)` is what ends this, straight into
    /// `collecting`: Freddy's call "starts listening immediately", never idly `listening` first.
    case entering
    case listening
    case collecting(startOffset: Int)
    /// "Stop" was heard at the boundary this range ends at; waiting on the pipeline's own final
    /// commit for the last few words before this can be assembled.
    case sending(range: SampleRange)
    /// The range is still short a committed segment somewhere inside it (a gap, not yet a
    /// timeout) — held rather than sent half-finished, and re-tried every time
    /// `ledgerChanged()` reports the gap might have closed.
    case pendingSend(range: SampleRange)
}

/// The call-mode state machine: what "start"/"stop"/"skip"/"mute"/"unmute"/"end" do to the call,
/// message assembly from a ledger's own committed segments, and the hold-while-gap rule for a
/// "stop" that lands before the pipeline has finished transcribing it.
///
/// Deliberately does not drive a socket, a ledger, or the command engine itself — those are the
/// pipeline's and the command channel's own blocks. This is the layer above them that turns their
/// shared, already-landed types (`TranscriptLedger`, `CommandEvent`) into what a call actually
/// does, which is what keeps it provable against a hand-built ledger and a scripted sequence of
/// commands rather than needing either of them running for real.
@MainActor
@Observable
public final class CallModeStore {
    public let sessionId: String
    public private(set) var phase: CallModePhase = .idle
    public private(set) var isMuted = false
    /// The range `pendingSend` is waiting on — `nil` whenever `phase` is not `.pendingSend`,
    /// mirrored here as a plain property so a caller does not have to pattern-match `phase` just
    /// to show "message pending transcription".
    public private(set) var pendingRange: SampleRange?
    public private(set) var sessionState: SessionState?
    public private(set) var blocker: Blocker?
    /// The bound session's own row status (`completed`/`deleted`/`error`, …) — a future "stop"
    /// is refused once this is terminal, per `sendingIsRefused`; the call itself stays open.
    public private(set) var sessionStatus: SessionStatus?
    /// Set when `postMessage` throws — the send itself already has its own recoverable-failure
    /// path (row `n`'s note on `dependencies.postMessage`); this is only call mode's own record
    /// of the last such failure, for whatever surface wants to announce it.
    public private(set) var lastSendFailure: Error?

    private let dependencies: CallModeDependencies

    /// Session statuses that end the underlying conversation — refuses new sends, but never ends
    /// the call itself: "sending refused", never "call disconnected", matching the design's own
    /// degradation table.
    private static let terminalStatuses: Set<SessionStatus> = [.completed, .deleted, .error]

    public init(sessionId: String, dependencies: CallModeDependencies) {
        self.sessionId = sessionId
        self.dependencies = dependencies
    }

    // MARK: - Lifecycle

    public func startEntering() {
        guard phase == .idle else { return }
        phase = .entering
    }

    /// Entering finished — the pipeline is capturing and the command engine is listening.
    public func finishEntering(atOffset offset: Int) {
        guard phase == .entering else { return }
        phase = .collecting(startOffset: offset)
    }

    /// The bound session's own agent-facing state (`SessionState`, from `LiveSessionStatus`) and
    /// its current blocker, if any — "the agent is waiting: `<blocker.question>`" is spoken from
    /// this, not from `sessionState`.
    public func liveStatusChanged(state: SessionState?, blocker: Blocker?) {
        sessionState = state
        self.blocker = blocker
    }

    /// Refuses further sends once `status` is terminal; the call stays open in `.listening`
    /// regardless, per the design's own degradation table. Decided lazily at send time
    /// (`sendingIsRefused`, read inside `trySend`) rather than acted on here, so a boundary
    /// already open when the session ends is still assembled and only the send itself is
    /// skipped.
    public func sessionStatusChanged(_ status: SessionStatus) {
        sessionStatus = status
    }

    // MARK: - Commands

    /// One command the offline engine (or the manual button standing in for it) accepted. Every
    /// accepted command earns its confirmation tone, whatever it turns out to do to `phase`.
    public func handle(_ command: CommandEvent) async {
        dependencies.feedback(.commandRecognized(command.kind))
        switch command.kind {
        case .start:
            guard case .listening = phase else { return }
            phase = .collecting(startOffset: command.atOffset)
        case .stop:
            guard case .collecting(let startOffset) = phase else { return }
            await handleStop(range: startOffset..<command.atOffset)
        case .skip:
            // Speech-out's own concern (`SpeechOutputSession.skip()`) — nothing about the call's
            // own phase changes for it.
            break
        case .mute:
            isMuted = true
        case .unmute:
            isMuted = false
        case .end:
            phase = .idle
        }
    }

    private var sendingIsRefused: Bool {
        if let sessionStatus, Self.terminalStatuses.contains(sessionStatus) { return true }
        return false
    }

    private func handleStop(range: SampleRange) async {
        phase = .sending(range: range)
        var elapsedMs = 0
        while WaitForCommitPolicy.shouldContinueWaiting(elapsedMs: elapsedMs, commitReceived: false) {
            if CallMessageAssembler.isCovered(range, in: dependencies.currentLedger()) { break }
            await dependencies.sleep(.milliseconds(WaitForCommitPolicy.pollIntervalMs))
            elapsedMs += WaitForCommitPolicy.pollIntervalMs
        }
        await trySend(range: range)
    }

    private func trySend(range: SampleRange) async {
        let ledger = dependencies.currentLedger()
        guard CallMessageAssembler.isCovered(range, in: ledger) else {
            phase = .pendingSend(range: range)
            pendingRange = range
            return
        }
        pendingRange = nil
        let text = CallMessageAssembler.assembledText(for: range, in: ledger)
        guard !text.isEmpty else {
            phase = .listening
            return
        }
        guard !sendingIsRefused else {
            phase = .listening
            return
        }
        do {
            try await dependencies.postMessage(text)
            phase = .listening
        } catch {
            lastSendFailure = error
            phase = .listening
        }
    }

    /// The pipeline's ledger changed — re-checks a held message, and only a held one; nothing
    /// else here reacts to every ledger write, matching "only `collecting` ranges are ever
    /// transcribed automatically or counted as a gap" from the design.
    public func ledgerChanged() async {
        guard case .pendingSend(let range) = phase else { return }
        await trySend(range: range)
    }

    // MARK: - Crash recovery

    /// A take recovered after a crash mid-call: `boundary` is a `.crashCut` the launch pass wrote
    /// for the stretch after the last confirmed send. Recovered text is never sent
    /// automatically — Freddy's own tap is what sends it, so this only assembles the text and
    /// returns the call to ordinary listening.
    public func recoverCrashCut(boundary: MessageBoundary, ledger: TranscriptLedger) -> String {
        let precedingOffset =
            ledger.boundaries
            .map(\.atOffset)
            .filter { $0 < boundary.atOffset }
            .max() ?? ledger.collecting.first?.lowerBound ?? 0
        let text = CallMessageAssembler.assembledText(for: precedingOffset..<boundary.atOffset, in: ledger)
        phase = .listening
        return text
    }
}
