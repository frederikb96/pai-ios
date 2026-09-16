import Foundation
import Observation

/// Everything `CallModeStore` needs that this package cannot provide itself. Reads the live take
/// through `currentLedger` rather than owning any pipeline state itself — `CallModeStore` never
/// mutates a ledger or drives a socket; it only decides, from the ledger's own committed segments
/// and gaps, when a turn is ready to become a sent message.
public struct CallModeDependencies: Sendable {
    /// The `WaitForCommitPolicy` poll loop's own wait — instant in tests, real in production.
    /// Everything else this store waits on (a held turn) is event-driven through
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

/// Where call mode is in its own lifecycle. `listening` (wake mode) and `collecting` (recording
/// mode) are the pair a call spends nearly all its time moving between; `entering`, `sending` and
/// `pendingSend` are the transient edges around them.
public enum CallModePhase: Sendable, Equatable {
    case idle
    /// Connecting the pipeline and the command channel — before call mode has anything to say
    /// about audio at all. `finishEntering(atOffset:)` is what ends this, straight into
    /// `collecting`: Freddy's call "starts listening immediately", never idly `listening` first.
    case entering
    /// Wake mode: only the offline command engine listens; no paid transcription is running.
    case listening
    /// Recording mode: ElevenLabs is transcribing into the turn, from `startOffset` onward.
    case collecting(startOffset: Int)
    /// "Send" was heard — either directly, or as the tail end of a "stop" the same command also
    /// carries when it fires from `collecting` — and the store is waiting on the pipeline's own
    /// final commit for the turn's last few words before it can be assembled.
    case sending
    /// The turn is still short a committed segment somewhere inside it (a gap, not yet a
    /// timeout) — held rather than sent half-finished, and re-tried every time
    /// `ledgerChanged()` reports the gap might have closed.
    case pendingSend
}

/// The call-mode state machine: what "start"/"stop"/"send"/"skip"/"end" do to the call, message
/// assembly from a ledger's own committed segments, and the hold-while-gap rule for a "send"
/// whose turn lands before the pipeline has finished transcribing it.
///
/// Freddy's chart has two listening states and no mute: **wake mode** (`listening`) — only the
/// offline command engine listens, no paid transcription runs — and **recording mode**
/// (`collecting`) — ElevenLabs transcribes into the turn. "Stop" moves recording back to wake
/// mode and keeps the transcribed text in the turn, unsent; "send" sends it, either directly from
/// recording mode (acting as stop-and-send in one) or from wake mode once a prior "stop" left a
/// turn pending. A turn can span several start/stop cycles before it is finally sent — `turnRanges`
/// is every `collecting` range contributed to it so far.
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
    /// Every `collecting` range contributed to the turn since it was last sent (by "send") or
    /// abandoned (by "end") — accumulated across as many start/stop cycles as Freddy likes before
    /// he says "send". Read directly rather than only during `.pendingSend`: it is what a caller
    /// shows for "message pending" the moment a "stop" leaves something queued, not only once a
    /// send is actually waiting on a gap.
    public private(set) var turnRanges: [SampleRange] = []
    /// Every command `handle(_:)` accepted since the turn began — what a send strips out of the
    /// assembled text (`CallMessageAssembler.assembledText(for:in:strippingCommands:)`) so "send"
    /// itself, heard from `.collecting`, does not land as the tail end of the very message it
    /// just triggered. Cleared everywhere `turnRanges` is: the two share exactly one lifetime.
    private var firedCommandsInTurn: [CommandEvent] = []
    public private(set) var sessionState: SessionState?
    public private(set) var blocker: Blocker?
    /// The bound session's own row status (`completed`/`deleted`/`error`, …) — a future send is
    /// refused once this is terminal, per `sendingIsRefused`; the call itself stays open.
    public private(set) var sessionStatus: SessionStatus?
    /// Set when `postMessage` throws — the send itself already has its own recoverable-failure
    /// path, documented on `CallModeDependencies.postMessage` above; this is only call mode's own
    /// record of the last such failure, for whatever surface wants to announce it.
    public private(set) var lastSendFailure: Error?
    /// Set when "end" was heard while the turn still held unsent text — whatever was assembled
    /// from `turnRanges` at that moment, never sent automatically (mirroring `recoverCrashCut`'s
    /// own hand-off): ending mid-turn is not meaningfully different from a crash mid-turn from
    /// the caller's point of view, since the words exist and Freddy never said "send". `nil`
    /// whenever "end" fired with nothing pending, and reset at the start of the next call.
    public private(set) var lastAbandonedTurnText: String?
    /// Set when a "send" was heard but the send itself never went out — refused by
    /// `sendingIsRefused`, or thrown by `postMessage`. Distinct from `lastSendFailure`: that is
    /// only the error, this is the text itself, the one thing a caller actually needs to hand
    /// back to Freddy rather than silently drop — without it, everything he said since the last
    /// successful send just disappears the moment a send is refused or fails. `nil` whenever the
    /// turn's most recent send outcome was itself `nil` (nothing pending) or succeeded.
    public private(set) var lastUnsentTurnText: String?

    private let dependencies: CallModeDependencies

    /// Reads and clears `lastUnsentTurnText` together — the store's own send outcome, and a
    /// caller's own delayed `.pendingSend` resolution (a ledger commit landing after "send" left
    /// the turn held on a gap) can both reach a place that would otherwise hand the same text off
    /// twice. There is exactly one caller for a given unsent turn; this is what makes that true
    /// rather than merely intended.
    public func consumeUnsentTurnText() -> String? {
        defer { lastUnsentTurnText = nil }
        return lastUnsentTurnText
    }

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
        turnRanges = []
        firedCommandsInTurn = []
        lastAbandonedTurnText = nil
        lastUnsentTurnText = nil
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
    /// (`sendingIsRefused`, read inside `trySend`) rather than acted on here, so a turn already
    /// open when the session ends is still assembled and only the send itself is skipped.
    public func sessionStatusChanged(_ status: SessionStatus) {
        sessionStatus = status
    }

    // MARK: - Commands

    /// One command the offline engine (or the fallback transcript recognizer, or a manual button
    /// standing in for either) accepted. Every accepted command earns its confirmation tone,
    /// whatever it turns out to do to `phase`.
    public func handle(_ command: CommandEvent) async {
        dependencies.feedback(.commandRecognized(command.kind))
        firedCommandsInTurn.append(command)
        switch command.kind {
        case .start:
            guard case .listening = phase else { return }
            phase = .collecting(startOffset: command.atOffset)
        case .stop:
            guard case .collecting(let startOffset) = phase else { return }
            turnRanges.append(startOffset..<command.atOffset)
            phase = .listening
        case .send:
            switch phase {
            case .collecting(let startOffset):
                // Acts as stop-and-send: the range still open when "send" was heard belongs to
                // the turn too.
                turnRanges.append(startOffset..<command.atOffset)
                await requestSend()
            case .listening where !turnRanges.isEmpty:
                await requestSend()
            default:
                // `.listening` with nothing pending, or already `.sending`/`.pendingSend`: no
                // turn to send, or one is already on its way.
                break
            }
        case .skip:
            // Speech-out's own concern (`SpeechOutputSession.skip()`) — nothing about the call's
            // own phase changes for it.
            break
        case .end:
            finishTurnOnEnd()
            phase = .idle
        }
    }

    private var sendingIsRefused: Bool {
        if let sessionStatus, Self.terminalStatuses.contains(sessionStatus) { return true }
        return false
    }

    private func requestSend() async {
        phase = .sending
        var elapsedMs = 0
        while WaitForCommitPolicy.shouldContinueWaiting(elapsedMs: elapsedMs, commitReceived: false) {
            if CallMessageAssembler.isCovered(turnRanges, in: dependencies.currentLedger()) { break }
            await dependencies.sleep(.milliseconds(WaitForCommitPolicy.pollIntervalMs))
            elapsedMs += WaitForCommitPolicy.pollIntervalMs
        }
        await trySend()
    }

    private func trySend() async {
        let ledger = dependencies.currentLedger()
        guard CallMessageAssembler.isCovered(turnRanges, in: ledger) else {
            phase = .pendingSend
            return
        }
        let assembled = CallMessageAssembler.assembledText(
            for: turnRanges, in: ledger, strippingCommands: firedCommandsInTurn)
        let text = assembled.isEmpty ? "" : "\(VoiceRecordingResult.sttPrefix)\(assembled)"
        turnRanges = []
        firedCommandsInTurn = []
        lastUnsentTurnText = nil
        guard !text.isEmpty else {
            phase = .listening
            return
        }
        guard !sendingIsRefused else {
            lastUnsentTurnText = text
            phase = .listening
            return
        }
        do {
            try await dependencies.postMessage(text)
            phase = .listening
        } catch {
            lastSendFailure = error
            lastUnsentTurnText = text
            phase = .listening
        }
    }

    /// The pipeline's ledger changed — re-checks a held turn, and only a held one; nothing else
    /// here reacts to every ledger write, matching "only `collecting` ranges are ever
    /// transcribed automatically or counted as a gap" from the design.
    public func ledgerChanged() async {
        guard case .pendingSend = phase else { return }
        await trySend()
    }

    /// The turn's own text as it stands right now — every closed range already in `turnRanges`,
    /// plus `openRange` (the still-recording cycle, if any), assembled from whatever the ledger
    /// has committed so far. Unlike `trySend`, never waits on a gap and never consumes anything:
    /// a caller showing this as a live preview polls it as often as it likes, gap or no gap,
    /// without disturbing what a later "send" will actually do.
    public func previewText(openRange: SampleRange?, in ledger: TranscriptLedger) -> String {
        var ranges = turnRanges
        if let openRange { ranges.append(openRange) }
        guard !ranges.isEmpty else { return "" }
        return CallMessageAssembler.assembledText(for: ranges, in: ledger, strippingCommands: firedCommandsInTurn)
    }

    /// Whatever the turn held is assembled best-effort (never waiting on a gap the way `send`
    /// does — ending abandons the take, not merely the turn) and handed to `lastAbandonedTurnText`
    /// rather than lost silently.
    private func finishTurnOnEnd() {
        guard !turnRanges.isEmpty else {
            lastAbandonedTurnText = nil
            return
        }
        let assembled = CallMessageAssembler.assembledText(
            for: turnRanges, in: dependencies.currentLedger(), strippingCommands: firedCommandsInTurn)
        turnRanges = []
        firedCommandsInTurn = []
        lastAbandonedTurnText = assembled.isEmpty ? nil : "\(VoiceRecordingResult.sttPrefix)\(assembled)"
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
        let text = CallMessageAssembler.assembledText(
            for: [precedingOffset..<boundary.atOffset], in: ledger)
        phase = .listening
        return text
    }
}
