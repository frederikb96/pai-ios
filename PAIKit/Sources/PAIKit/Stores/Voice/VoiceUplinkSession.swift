import Foundation
import Observation

/// Everything `VoiceUplinkSession` needs that this package cannot provide itself — same shape as
/// the ElevenLabs-era `VoiceRecordingDependencies`: closures read at call time, not values
/// captured once, so a token or a setting change takes effect on the next attempt without
/// rebuilding anything.
public struct VoiceUplinkDependencies: Sendable {
    public var makeTransport: @Sendable () -> any VoiceSocketTransportProtocol
    public var socketURL: @Sendable () throws -> URL
    /// The bearer token this connection authenticates with — read fresh on every `hello`, the
    /// same token every other request in the app already uses.
    public var authToken: @Sendable () -> String?
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Duration) async -> Void
    public var feedback: @Sendable (FeedbackEvent) -> Void
    public var connectionEvent: @Sendable (ConnectionHealthEvent) -> Void

    public init(
        makeTransport: @escaping @Sendable () -> any VoiceSocketTransportProtocol,
        socketURL: @escaping @Sendable () throws -> URL,
        authToken: @escaping @Sendable () -> String?,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        feedback: @escaping @Sendable (FeedbackEvent) -> Void = { _ in },
        connectionEvent: @escaping @Sendable (ConnectionHealthEvent) -> Void = { _ in }
    ) {
        self.makeTransport = makeTransport
        self.socketURL = socketURL
        self.authToken = authToken
        self.now = now
        self.sleep = sleep
        self.feedback = feedback
        self.connectionEvent = connectionEvent
    }
}

/// Why the uplink could not even attempt a connection — distinct from a mid-take drop
/// (`VoiceRecordingState.reconnecting`), which is not a start failure at all.
public enum VoiceUplinkStartFailure: Error, Sendable, Equatable {
    case notAuthenticated
    case malformedBackendURL
    case other(String)
}

extension VoiceUplinkStartFailure {
    public var userMessage: String {
        switch self {
        case .notAuthenticated: return "You're not signed in."
        case .malformedBackendURL: return "The backend address isn't configured correctly."
        case .other(let detail): return detail
        }
    }
}

/// How long `VoiceUplinkSession` waits before each reconnect attempt. Every drop is retried
/// whatever its reason — a phone losing signal mid-pocket carries no reason at all — and the
/// delay grows then holds at its ceiling for as long as the take keeps running: over the length
/// of a take this pipeline is built for, a dead patch of signal is ordinary, not exceptional, and
/// nothing about a retry count should be the reason a take ends.
public enum VoiceUplinkReconnectPolicy {
    /// Seconds. The last value repeats for any attempt past the array's length.
    public static let backoffSeconds = [2, 4, 8, 16, 30]

    public static func delaySeconds(forAttempt attempt: Int) -> Int {
        let index = min(max(attempt, 1), backoffSeconds.count) - 1
        return backoffSeconds[index]
    }
}

/// The uplink half of the two-module split: the module that knows a backend exists at all. Reads
/// PCM the recorder is already writing to its durable file (`ingestAudioChunk`, unchanged
/// contract from the ElevenLabs-era `VoiceRecordingSession`), ships it as binary frames over
/// `docs/VOICE_PROTOCOL.md`'s `/api/voice/socket`, and owns everything about whether that
/// shipment is currently succeeding — the gate, the ack watermark, reconnect and its backoff, and
/// the liveness this socket's own `ping`/`pong` pair is the sole authority for.
///
/// What this type deliberately does NOT hold, unlike its ElevenLabs-era predecessor: no partial
/// or committed transcript text. The backend writes committed words straight into the session's
/// draft region (`DraftRegionSink`, server-side) — a client dictating into a draft never receives
/// them back over this socket at all (`docs/VOICE_PROTOCOL.md`: "Composer text sync ... is REST +
/// SSE, not this socket"). What a caller renders while this runs is `DraftStore`'s own composed
/// text for the draft key this session is pointed at, not anything here.
///
/// `@MainActor` for the same reason `VoiceRecordingSession` was: every realistic caller is a
/// UI-driven view model, and the event rate (an ack every audio frame, a ping every 5s) is
/// nowhere near where hopping onto the main actor per call would cost anything.
@MainActor
@Observable
public final class VoiceUplinkSession {
    /// Comfortably above the backend's own 5s ping interval + 5s timeout
    /// (`pai_cloud/voice/bus.py`'s `PING_INTERVAL_S`/`PING_TIMEOUT_S`) — long enough that one
    /// missed ping under ordinary jitter is not mistaken for a dead link, short enough that a
    /// socket silently carrying nothing (open, but stopped delivering) is still caught rather
    /// than trusted forever, matching the protocol doc's own "never by a boolean connected flag"
    /// rule.
    static let watchdogTimeoutSeconds: TimeInterval = 12

    /// How long `stop()` waits, once the gate is closed, for `take_done` to arrive before giving
    /// up and closing anyway — the stop-recording design's own D1. Comfortably below the
    /// backend's own worst case (a ~25s forced-commit ceiling plus one batch request): those are
    /// exactly the slow cases where the honest answer is "still transcribing, the rest is
    /// coming", not a longer wait.
    public static let finishingDeadlineSeconds: TimeInterval = 8

    public private(set) var state: VoiceRecordingState = .idle
    public private(set) var isMuted = false
    /// How much of this take has been captured (handed to `ingestAudioChunk`) so far.
    public private(set) var capturedUpTo = 0
    /// The highest take-sample-offset the backend has acknowledged as durably received — what
    /// `TranscriptLedger.derivedGaps` reads as "delivered" once the caller folds this into an
    /// `acknowledged` range, and what a reconnect resumes sending from.
    public private(set) var ackedUpTo = 0
    public private(set) var lastEndReason: RecordingEndReason?
    public private(set) var lastStartFailure: VoiceUplinkStartFailure?
    /// Why the socket last went away mid-take — a close reason, or a `notice` the backend sent
    /// before it. The take reconnects either way; this is what a take that eventually gave up can
    /// still say about why.
    public private(set) var lastDisconnectDetail: String?
    public private(set) var lastNotice: (severity: String, code: String, text: String)?

    /// Every committed segment for the current take, space-joined in arrival order — arrival
    /// order rather than `end_sample` order, since a live take's frames arrive in the order the
    /// engine committed them and reordering here would require holding every segment back until
    /// its neighbours are known. `end_sample` still orders a late backfilled segment relative to
    /// these, but that reconciliation is the caller's (`VoiceRecorderController`'s), not this
    /// type's — see this run's own report on the one accepted gap that follows from it.
    public private(set) var committedText = ""
    /// The current take's own live partial — replaced whole by every `is_final: false` frame,
    /// cleared the moment its words are committed. Never persisted anywhere on its own; a caller
    /// reads ``composedText`` for what to show.
    public private(set) var currentPartial = ""
    /// What a composer should show for the running take: every committed word so far, plus
    /// whatever is still being said. `pre + " " + composedText` is the caller's job — this type
    /// has no idea what preceded the take.
    public var composedText: String {
        [committedText, currentPartial].filter { !$0.isEmpty }.joined(separator: " ")
    }
    /// The last `seq` this take has actually applied (committed or partial alike) — compared
    /// against `take_done.finalSeq` to tell a complete take from one that lost a frame across a
    /// reconnect and needs its own backfill rather than a wait.
    public private(set) var highestAppliedSeq = -1
    /// Set once `take_done` arrives for the current take — the stop sequence's own completion
    /// signal, read rather than inferred from a partial going quiet (R3).
    public private(set) var lastTakeDone: (takeId: String, finalSeq: Int, ended: String)?
    /// Takes this client has sealed locally (Send or Skip pressed during Finishing) — every later
    /// `transcript` frame naming one of these is dropped on arrival, so words already in flight
    /// when the take was abandoned can never resurrect text the composer has moved past.
    private var abandonedTakeIds: Set<String> = []

    private let dependencies: VoiceUplinkDependencies
    private var transport: (any VoiceSocketTransportProtocol)?
    private var receiveTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    /// This socket's own frame counter — restarts at 0 on EVERY `ready`, fresh bus or resumed
    /// alike (`docs/VOICE_PROTOCOL.md`, "Framing": "`seq` always restarts at 0 on the reconnected
    /// socket, even when `ready.resumed` is `true`" — `seq` is scoped to this client connection,
    /// never to the bus). `inFlight` is cleared alongside it in the `.ready` handler for the same
    /// reason: its keys are this socket's own `seq` values, and a stale entry from the connection
    /// this one replaced would otherwise collide with the new socket's own seq 0, 1, 2, ….
    private var nextSeq = 0
    private var resumeToken: String?
    private var currentDraftKey: String?
    /// This take's own client-minted identity, carried on `gate open` so the backend's
    /// `start_take(take_id:)` addresses the same draft region on every reconnect within this
    /// take, and a long-outage recovery can still reach it by name once the bus itself is gone
    /// (`docs/VOICE_PROTOCOL.md` "Addressing a take"). `nil` for a caller not dictating into a
    /// draft at all.
    private var currentTakeId: String?
    private var recordingStart: Date?
    private var mutedMs = 0
    private var lastMuteToggle: Date?
    private var lastReceiveAt: Date?
    private var isStopping = false
    /// Set the instant the receive loop dies while `isStopping` — `handleConnectionLost` itself
    /// no-ops in that state (reconnecting mid-teardown would be wrong), so this is the one signal
    /// ``waitForTakeDone(takeId:)`` has that the socket it is waiting on is already gone. Reset on
    /// every fresh `start()`.
    private var socketDiedDuringStop = false
    /// Audio captured while the socket is down or still connecting — flushed in `sampleOffset`
    /// order the moment a `ready` (fresh or resumed) arrives, so nothing captured during a brief
    /// drop is lost even though it could not be sent live.
    private var pendingChunks: [(offset: Int, samples: [Int16])] = []

    public init(dependencies: VoiceUplinkDependencies) {
        self.dependencies = dependencies
    }

    public var canStart: Bool { state == .idle }

    /// Whether `ingestAudioChunk` would actually accept audio fed to it right now.
    public var canIngestAudio: Bool {
        state == .recording || state == .connecting || state == .reconnecting
    }

    public var result: (endedBy: RecordingEndReason, durationMs: Int, mutedMs: Int) {
        (
            endedBy: lastEndReason ?? .user,
            durationMs: recordingStart.map { Int(dependencies.now().timeIntervalSince($0) * 1000) } ?? 0,
            mutedMs: mutedMs
        )
    }

    // MARK: - Start

    public func start(draftKey: String?, takeId: String? = nil) async {
        guard state == .idle else { return }
        lastStartFailure = nil
        lastDisconnectDetail = nil
        lastEndReason = nil
        isMuted = false
        mutedMs = 0
        lastMuteToggle = nil
        capturedUpTo = 0
        ackedUpTo = 0
        nextSeq = 0
        resumeToken = nil
        currentDraftKey = draftKey
        currentTakeId = takeId
        recordingStart = dependencies.now()
        reconnectAttempt = 0
        isStopping = false
        socketDiedDuringStop = false
        pendingChunks = []
        committedText = ""
        currentPartial = ""
        highestAppliedSeq = -1
        lastTakeDone = nil
        abandonedTakeIds = []

        guard let token = dependencies.authToken(), !token.isEmpty else {
            lastStartFailure = .notAuthenticated
            return
        }
        let url: URL
        do {
            url = try dependencies.socketURL()
        } catch {
            lastStartFailure = .malformedBackendURL
            return
        }

        state = .connecting
        await connect(url: url, token: token)
    }

    // MARK: - Connect / reconnect

    private func connect(url: URL, token: String) async {
        let transport = dependencies.makeTransport()
        self.transport = transport
        dependencies.connectionEvent(.socketOpened)
        do {
            try await transport.connect(url: url)
            try await transport.send(
                .hello(
                    transport: VoiceSocketProtocol.transportName,
                    caps: VoiceSocketCapabilities(audioDownlink: true, dtmf: false),
                    auth: token,
                    resumeToken: resumeToken,
                    draftKey: currentDraftKey
                )
            )
        } catch {
            dependencies.connectionEvent(.socketClosed(reason: "\(error)"))
            await scheduleReconnect(reason: "\(error)")
            return
        }

        lastReceiveAt = dependencies.now()
        startWatchdog()
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
    }

    private func receiveLoop() async {
        guard let transport else { return }
        while true {
            let message: VoiceSocketMessage
            do {
                message = try await transport.receive()
            } catch {
                let detail: String? = {
                    if case let VoiceSocketTransportError.connectionLost(reason) = error { return reason }
                    return "\(error)"
                }()
                // `handleConnectionLost` itself no-ops while `isStopping` — reconnecting mid-stop
                // would be wrong — so this is what tells `waitForTakeDone(takeId:)` the socket it
                // is waiting on has already died, rather than leaving it to run out the full
                // deadline for no reason.
                if isStopping {
                    socketDiedDuringStop = true
                    return
                }
                await handleConnectionLost(detail: detail)
                return
            }
            lastReceiveAt = dependencies.now()
            switch message {
            case let .audio(ref, _):
                // Downlink audio (synthesized speech) has no meaning for a plain dictation take —
                // this sink never dictates into a bus carrying one. Acked so a future engine that
                // does send audio here is never left waiting on a `played` it will never get.
                try? await transport.send(.played(ref: ref))
            case let .control(frame):
                await handle(frame)
            }
        }
    }

    private func handle(_ frame: VoiceDownFrame) async {
        switch frame {
        case let .ready(newResumeToken, _, resumed, _):
            resumeToken = newResumeToken
            reconnectAttempt = 0
            dependencies.connectionEvent(.mintSucceeded)
            let wasReconnecting = state == .reconnecting
            state = isStopping ? state : .recording
            // `seq` restarts at 0 on every socket regardless of `resumed` — the socket's own
            // counter, never the bus's (`docs/VOICE_PROTOCOL.md`, "Framing"). `inFlight`'s keys
            // are this socket's own `seq` values, so a stale entry from the connection this one
            // replaced would otherwise collide with the new socket's own seq 0, 1, 2, ….
            nextSeq = 0
            inFlight = [:]
            if !resumed {
                // A genuinely fresh bus needs this, including the very first connect of a
                // brand-new take: the take must be (re)opened server-side, or every word
                // transcribed from here has nowhere to land. A fresh bus also means the ack
                // watermark reset to nothing on the server's side; resume sending from wherever
                // local delivery is actually confirmed, so nothing already acked is resent, but
                // nothing captured since is skipped either.
                ackedUpTo = 0
                // `takeId` rides on EVERY open now, not only the first — there is no server-side
                // region any more whose own stored `seq` a resent id could collide with (that
                // hazard was specific to `DraftRegionSink`'s region model, and drafts v2 has none).
                // Re-sending the same id is what keeps a take addressable across a reconnect at
                // all (wire contract §3 R4): the server writes no draft for dictation any more, so
                // there is nothing left for a fresh id to mint in its place.
                try? await transport?.send(.gate(open: true, reason: "button", takeId: currentTakeId))
            }
            if wasReconnecting {
                dependencies.feedback(.reconnected)
            }
            await flushPending()
        case let .ack(throughSeq):
            dependencies.connectionEvent(.socketDelivered)
            // `throughSeq` addresses this connection's own `seq` numbering, not a sample offset —
            // this session sends one frame per `ingestAudioChunk` call, so the watermark is
            // whatever sample offset the frame with that `seq` carried, plus its own sample count.
            // Tracked via `inFlight` rather than recomputed, since frame sizes are not uniform.
            if let acked = inFlight[throughSeq] {
                ackedUpTo = max(ackedUpTo, acked)
            }
            inFlight = inFlight.filter { $0.key > throughSeq }
        case .clear:
            break
        case let .state(_, phase, _, _):
            lastNotice = phase == "listening" ? nil : lastNotice
        case let .notice(severity, code, text):
            lastNotice = (severity, code, text)
            if code == VoiceNoticeCode.authExpired {
                lastDisconnectDetail = text
                await stopInternal(reason: .connectionLost, abandon: false)
            } else if severity == "warning" || severity == "error" {
                dependencies.feedback(.serverNotice(text))
            }
        case .ping:
            try? await transport?.send(.pong)
        case let .transcript(takeId, seq, isFinal, text, _):
            // A frame naming a take this client has already sealed (Send/Skip pressed during
            // Finishing) is dropped on arrival — the composed text is frozen at what the box
            // showed the moment it was sealed, and nothing arriving after may reopen it.
            if let takeId, abandonedTakeIds.contains(takeId) { break }
            highestAppliedSeq = max(highestAppliedSeq, seq)
            if isFinal {
                committedText = committedText.isEmpty ? text : "\(committedText) \(text)"
                currentPartial = ""
            } else {
                currentPartial = text
            }
        case let .takeDone(takeId, finalSeq, ended):
            guard !abandonedTakeIds.contains(takeId) else { break }
            lastTakeDone = (takeId, finalSeq, ended)
        case .unrecognized:
            break
        }
    }

    /// Seals a take locally — every later `transcript`/`take_done` frame naming it is dropped, and
    /// the composed text is frozen at whatever the caller already captured. Call this BEFORE
    /// sending the abandon gate (the wire contract's own ordering: seal, then tell the server),
    /// never after — a frame that arrives in the gap between would otherwise still land.
    public func sealTake(_ takeId: String) {
        abandonedTakeIds.insert(takeId)
    }

    /// Frames sent, keyed by their own `seq`, to the take-relative sample offset they end at —
    /// what an `ack` resolves into `ackedUpTo`. Pruned as acks arrive; unbounded only while a
    /// connection genuinely owes more acks than it has received, which the backend's own 5s ping
    /// cadence bounds in practice.
    private var inFlight: [Int: Int] = [:]

    private func handleConnectionLost(detail: String?) async {
        guard state != .idle, !isStopping else { return }
        stopWatchdog()
        dependencies.connectionEvent(.socketClosed(reason: detail))
        lastDisconnectDetail = detail
        let wasRecording = state == .recording
        state = .reconnecting
        if wasRecording {
            dependencies.feedback(.connectionDropped(reason: detail))
        }
        await scheduleReconnect(reason: detail ?? "connection lost")
    }

    private func scheduleReconnect(reason: String) async {
        guard !isStopping else { return }
        reconnectAttempt += 1
        let delaySeconds = VoiceUplinkReconnectPolicy.delaySeconds(forAttempt: reconnectAttempt)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            await self.dependencies.sleep(.seconds(delaySeconds))
            guard !Task.isCancelled else { return }
            await self.attemptReconnect()
        }
    }

    private func attemptReconnect() async {
        guard !isStopping, state != .idle else { return }
        guard let token = dependencies.authToken(), !token.isEmpty else {
            lastStartFailure = .notAuthenticated
            return
        }
        guard let url = try? dependencies.socketURL() else {
            lastStartFailure = .malformedBackendURL
            return
        }
        await connect(url: url, token: token)
    }

    /// Forces a reconnect right now — the watchdog's own remedy for a socket that stopped
    /// carrying anything without ever throwing (the protocol doc's "a socket can sit open and
    /// silently stop carrying anything in either direction").
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            guard let self else { return }
            while true {
                await self.dependencies.sleep(.seconds(Int(Self.watchdogTimeoutSeconds)))
                guard !Task.isCancelled else { return }
                guard let lastReceiveAt = await self.lastReceiveAt else { continue }
                let elapsed = await self.dependencies.now().timeIntervalSince(lastReceiveAt)
                guard elapsed >= Self.watchdogTimeoutSeconds else { continue }
                await self.handleConnectionLost(detail: "no traffic for \(Int(elapsed))s")
                return
            }
        }
    }

    private func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    // MARK: - Ingest

    /// Hands one already-captured, already-durable-file-written buffer to the uplink. Contract
    /// unchanged from the ElevenLabs-era `VoiceRecordingSession.ingestAudioChunk`: the caller
    /// resamples to the transport rate first, this never does its own conversion, and a chunk
    /// arriving while `canIngestAudio` is false is silently dropped (the recorder itself never
    /// stops — only this session's opinion about sending it changes).
    public func ingestAudioChunk(pcm16le samples: [Int16], at offset: Int) async {
        guard canIngestAudio, !samples.isEmpty else { return }
        capturedUpTo = max(capturedUpTo, offset + samples.count)
        let toSend = isMuted ? [Int16](repeating: 0, count: samples.count) : samples
        guard state == .recording, let transport else {
            pendingChunks.append((offset, toSend))
            return
        }
        await send(offset: offset, samples: toSend, transport: transport)
    }

    private func send(offset: Int, samples: [Int16], transport: any VoiceSocketTransportProtocol) async {
        let seq = nextSeq
        nextSeq += 1
        inFlight[seq] = offset + samples.count
        let frame = VoiceSocketProtocol.packUplinkAudio(seq: seq, sampleOffset: offset, pcm16le: samples)
        do {
            try await transport.sendAudio(frame)
        } catch {
            // The receive loop's own `catch` is what declares the connection lost and reconnects
            // — a send failure on the same dead socket would otherwise race it to the same
            // conclusion twice.
        }
    }

    private func flushPending() async {
        guard let transport, !pendingChunks.isEmpty else { return }
        let queued = pendingChunks
        pendingChunks = []
        for chunk in queued {
            await send(offset: chunk.offset, samples: chunk.samples, transport: transport)
        }
    }

    // MARK: - Interruption / manual retry

    /// The system took the microphone (a call, Siri, another app) — capture has already stopped
    /// by the time this is called; this only stops the uplink from fighting the backoff clock
    /// while there is nothing to send anyway. The socket itself is left alone: an `AVAudioSession`
    /// interruption says nothing about the network, so a connection that is still healthy stays
    /// that way and `resumeAfterInterruption()` can pick up exactly where it left off.
    public func pauseForInterruption() {
        guard state == .recording || state == .connecting || state == .reconnecting else { return }
        reconnectTask?.cancel()
        state = .paused
    }

    /// `shouldResume == false` (the caller's own concern, not this method's) means the take is
    /// ending, not resuming — see `VoiceRecorderController.giveUpAfterInterruption`.
    public func resumeAfterInterruption() {
        guard state == .paused else { return }
        if transport != nil {
            state = .recording
            Task { await flushPending() }
        } else {
            state = .reconnecting
            Task { await attemptReconnect() }
        }
    }

    /// "On path satisfied, attempt immediately" — skips whatever backoff a reconnect is still
    /// waiting out, since a network path just became available is exactly the signal that makes
    /// waiting out the rest of it pointless.
    public func retryReconnectNow() {
        guard state == .reconnecting else { return }
        reconnectTask?.cancel()
        Task { await attemptReconnect() }
    }

    // MARK: - Mute

    public func toggleMute() {
        let now = dependencies.now()
        if isMuted, let lastMuteToggle {
            mutedMs += Int(now.timeIntervalSince(lastMuteToggle) * 1000)
        }
        isMuted.toggle()
        lastMuteToggle = now
    }

    // MARK: - Stop

    /// The ordinary stop: closes the gate, then holds the socket open through Finishing —
    /// answering pings, still receiving frames — until `take_done` arrives for this take, the
    /// deadline passes, or the socket itself dies, whichever comes first (R1–R5). Exits
    /// immediately, with none of that waiting, when there was no live connection to drain in the
    /// first place: `state` at the moment of the call is what decides whether waiting can mean
    /// anything at all.
    public func stop(reason: RecordingEndReason = .user) async {
        guard state != .idle else { return }
        await stopInternal(reason: reason, abandon: false)
    }

    /// Ends the take WITHOUT waiting for its tail — what a send pressed during Finishing does
    /// (wire contract §3). The server skips its own forced commit and batch recovery and closes
    /// immediately, so waiting here would only be waiting on a wait the server itself is not
    /// doing. The caller must call ``sealTake(_:)`` with this take's id BEFORE this, not after —
    /// a frame already in flight when this is called could otherwise still land afterwards.
    public func abandon() async {
        guard state != .idle else { return }
        await stopInternal(reason: .user, abandon: true)
    }

    private func stopInternal(reason: RecordingEndReason, abandon: Bool) async {
        isStopping = true
        // Only `.recording` names a socket actually worth talking to — `.connecting`/
        // `.reconnecting`/`.paused` have no live gate to close and nothing to wait on, which is
        // exactly the "no connection" exit: Finishing is never entered for them at all, by
        // construction, rather than by a timer that happens to expire instantly.
        let wasConnected = state == .recording
        state = .stopping
        let takeId = currentTakeId
        if wasConnected, let transport {
            try? await transport.send(.gate(open: false, reason: abandon ? "abandon" : "button"))
            if !abandon, let takeId {
                await waitForTakeDone(takeId: takeId)
            }
        }
        stopWatchdog()
        reconnectTask?.cancel()
        receiveTask?.cancel()
        if wasConnected, let transport {
            try? await transport.send(.bye(reason: "stop"))
            await transport.close(code: 1000, reason: "stop")
        }
        transport = nil
        lastEndReason = reason
        state = .idle
        isStopping = false
    }

    /// R1 ∧ R3: waits for the one positive completion signal there is — `take_done` for this
    /// exact take — never for a partial merely going quiet, which looks identical to a stalled
    /// connection. Exits early on the deadline (R2's own budget) or on the socket dying mid-wait
    /// (`socketDiedDuringStop`, since `handleConnectionLost` itself no-ops while stopping).
    private func waitForTakeDone(takeId: String) async {
        let deadlineAt = dependencies.now().addingTimeInterval(Self.finishingDeadlineSeconds)
        while true {
            if lastTakeDone?.takeId == takeId { return }
            if socketDiedDuringStop { return }
            if dependencies.now() >= deadlineAt { return }
            await dependencies.sleep(.milliseconds(100))
        }
    }
}
