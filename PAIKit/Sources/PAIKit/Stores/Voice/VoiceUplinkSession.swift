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
    /// The client-local gate setting, read once per take; `nil` runs the take with no gate.
    public var silenceGate: @Sendable () -> SilenceGateSettings?
    /// This phone and its current microphone, sent on every `hello`.
    public var device: @Sendable () -> VoiceDeviceInfo?
    /// One line for the voice diagnostics log.
    public var log: @Sendable (String) -> Void

    public init(
        makeTransport: @escaping @Sendable () -> any VoiceSocketTransportProtocol,
        socketURL: @escaping @Sendable () throws -> URL,
        authToken: @escaping @Sendable () -> String?,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        feedback: @escaping @Sendable (FeedbackEvent) -> Void = { _ in },
        connectionEvent: @escaping @Sendable (ConnectionHealthEvent) -> Void = { _ in },
        silenceGate: @escaping @Sendable () -> SilenceGateSettings? = { nil },
        device: @escaping @Sendable () -> VoiceDeviceInfo? = { nil },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.makeTransport = makeTransport
        self.socketURL = socketURL
        self.authToken = authToken
        self.now = now
        self.sleep = sleep
        self.feedback = feedback
        self.connectionEvent = connectionEvent
        self.silenceGate = silenceGate
        self.device = device
        self.log = log
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
/// PCM the recorder is already writing to its durable file (`ingestAudioChunk`), ships it as binary
/// frames over `docs/VOICE_PROTOCOL.md`'s `/api/voice/socket`, and owns everything about whether
/// that shipment is currently succeeding — the gate, which stretches the backend has stored
/// (`acknowledgedRanges`), reconnect and its backoff, and the liveness this socket's own
/// `ping`/`pong` pair is the sole authority for.
///
/// A live take's words come back as `transcript` frames, which this type assembles
/// (`composedText`); the caller writes them into the draft. A batch take sends no words while it
/// records. Either way the take itself is a server-side resource that outlives this socket: what
/// the socket never delivered is uploaded into the take over REST from the durable file, so audio
/// this type cannot send is simply left unacknowledged, never replayed in bulk.
///
/// `@MainActor` because every realistic caller is a UI-driven view model, and the event rate (an
/// ack every audio frame, a ping every 5s) is nowhere near where hopping onto the main actor per
/// call would cost anything.
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

    /// How long `stop()` waits, once the gate is closed, for the take's receipt — `take_done` for
    /// a live take, a `take_state` past `open` for a batch one — before closing anyway. The
    /// finishing control stays pressable meanwhile, and leaving early loses nothing: the server
    /// holds the audio and finishes the take on its own.
    public static let finishingDeadlineSeconds: TimeInterval = 30

    /// The most audio held in memory while the socket is down or still connecting. Anything older
    /// is dropped from the queue — it is already on disk, stays unacknowledged, and is uploaded
    /// into the take over REST — so an hour without signal costs twenty seconds of memory rather
    /// than an hour of it, and a reconnect never pushes more into realtime transcription than the
    /// backend accepts as a replay.
    public static let maxQueuedSeconds = 20

    public private(set) var state: VoiceRecordingState = .idle
    public private(set) var isMuted = false
    /// How much of this take has been captured (handed to `ingestAudioChunk`) so far.
    public private(set) var capturedUpTo = 0
    /// What the backend has acknowledged as stored, merged and sorted.
    private var ackedRanges: [SampleRange] = []
    public private(set) var lastEndReason: RecordingEndReason?
    public private(set) var lastStartFailure: VoiceUplinkStartFailure?
    /// Why the socket last went away mid-take — a close reason, or a `notice` the backend sent
    /// before it. The take reconnects either way; this is what a take that eventually gave up can
    /// still say about why.
    public private(set) var lastDisconnectDetail: String?
    public private(set) var lastNotice: (severity: String, code: String, text: String)?
    /// The silence gate is holding the microphone back right now — what the volume overlay dims
    /// for.
    public var isWithholding: Bool { gate?.isWithholding ?? false }
    /// The level gate for this take, built from the setting at start.
    private var gate: SilenceGate?

    /// Every stretch of the take that needs nothing more from this device: stored by the backend,
    /// or withheld by the silence gate. Everything captured outside these is owed — still on its
    /// way over the socket, or a gap to upload.
    public var acknowledgedRanges: [SampleRange] {
        var settled = ackedRanges + (gate?.withheldRanges ?? [])
        if let open = gate?.openWithheldRange { settled.append(open) }
        return TranscriptLedger.merge(settled)
    }

    /// The stretches the silence gate withheld — what the seal reports as `withheld`.
    public var withheldRanges: [SampleRange] { gate?.withheldRanges ?? [] }

    /// The first sample the socket may still deliver: the oldest frame sent and not yet
    /// acknowledged, the oldest queued for the next connection, or the pre-roll the gate holds
    /// back. Unacknowledged audio before this is a gap nothing here will ever send.
    public var uplinkFrontier: Int {
        let candidates = [pendingChunks.first?.offset, inFlight.values.map(\.lowerBound).min(), gate?.heldBackFrom]
        return candidates.compactMap { $0 }.reduce(capturedUpTo) { min($0, $1) }
    }

    /// One committed segment, addressed by its take-absolute end sample rather than by arrival
    /// order — a batch-recovered stretch for an earlier gap can arrive after live segments that
    /// followed it in time, and only the sample position sorts them back into spoken order.
    private struct CommittedSegment {
        let endSample: Int
        let seq: Int
        let text: String
    }
    private var committedSegments: [CommittedSegment] = []

    /// Every committed segment for the current take, joined in take order — never arrival order.
    public var committedText: String {
        sortedSegments.map(\.text).joined(separator: " ")
    }
    /// The same committed segments, placed by their take-absolute end sample — what the take's
    /// ledger keeps as its live text.
    public var committedLiveText: [LiveTextSegment] {
        sortedSegments.map { LiveTextSegment(endSample: $0.endSample, text: $0.text) }
    }
    private var sortedSegments: [CommittedSegment] {
        committedSegments.sorted { ($0.endSample, $0.seq) < ($1.endSample, $1.seq) }
    }
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
    /// reconnect.
    public private(set) var highestAppliedSeq = -1
    /// Set once `take_done` arrives for the current take.
    public private(set) var lastTakeDone: (takeId: String, finalSeq: Int, ended: String)?
    /// The take store's last word on the current take over this socket (`take_state`).
    public private(set) var lastTakeState: VoiceTakeState?
    /// What the take asks of the transcription engine, fixed at `start`.
    public private(set) var sttMode: VoiceSttMode = .live

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
    /// reason: its keys are this socket's own `seq` values.
    private var nextSeq = 0
    private var resumeToken: String?
    private var currentDraftKey: String?
    private var isStandalone = false
    /// This take's own client-minted identity, carried on every `gate open` and on the close, so
    /// every reconnect within the take addresses the same server-side take
    /// (`docs/VOICE_PROTOCOL.md` "Addressing a take").
    private var currentTakeId: String?
    private var recordingStart: Date?
    private var mutedMs = 0
    private var lastMuteToggle: Date?
    private var lastReceiveAt: Date?
    private var isStopping = false
    /// Set the instant the receive loop dies while `isStopping` — `handleConnectionLost` itself
    /// no-ops in that state, so this is the one signal the finishing wait has that the socket it
    /// is waiting on is already gone. Reset on every fresh `start()`.
    private var socketDiedDuringStop = false
    /// Set by ``stopWaiting()``: the person left, typed, or sent — the finishing wait returns at
    /// once. Reset on every fresh `start()`.
    private var stopWaitingRequested = false
    /// Audio captured while the socket is down or still connecting, oldest first, capped at
    /// ``maxQueuedSeconds`` — flushed the moment a `ready` arrives.
    private var pendingChunks: [(offset: Int, samples: [Int16])] = []
    private var pendingSampleCount = 0

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

    /// `draftKey` names the draft a dictation is typed into; `standalone` is a recording with no
    /// draft. A take carries exactly one of the two.
    public func start(
        draftKey: String?, takeId: String? = nil, sttMode: VoiceSttMode = .live, standalone: Bool = false
    ) async {
        guard state == .idle else { return }
        lastStartFailure = nil
        lastDisconnectDetail = nil
        lastEndReason = nil
        isMuted = false
        mutedMs = 0
        lastMuteToggle = nil
        capturedUpTo = 0
        ackedRanges = []
        inFlight = [:]
        nextSeq = 0
        resumeToken = nil
        currentDraftKey = draftKey
        isStandalone = standalone
        currentTakeId = takeId
        self.sttMode = sttMode
        recordingStart = dependencies.now()
        reconnectAttempt = 0
        isStopping = false
        socketDiedDuringStop = false
        stopWaitingRequested = false
        pendingChunks = []
        pendingSampleCount = 0
        committedSegments = []
        currentPartial = ""
        highestAppliedSeq = -1
        lastTakeDone = nil
        lastTakeState = nil
        gate = dependencies.silenceGate().map { SilenceGate(settings: $0) }

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
                    caps: VoiceSocketCapabilities(
                        audioDownlink: true, dtmf: false, silenceGate: gate?.settings.enabled == true),
                    auth: token,
                    resumeToken: resumeToken,
                    draftKey: isStandalone ? nil : currentDraftKey,
                    device: dependencies.device(),
                    sttMode: currentTakeId == nil ? nil : sttMode,
                    standalone: isStandalone
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
                // would be wrong — so this is what tells the finishing wait the socket it is
                // waiting on has already died, rather than leaving it to run out the deadline.
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
        case let .ready(newResumeToken, _, resumed, _, silenceAllowed):
            resumeToken = newResumeToken
            // A fresh connection starts streaming with no memory of the room; whatever a gate
            // decided while the socket was down is settled here rather than queued.
            gate?.reset()
            _ = gate?.setAllowed(silenceAllowed)
            reconnectAttempt = 0
            dependencies.connectionEvent(.mintSucceeded)
            let wasReconnecting = state == .reconnecting
            state = isStopping ? state : .recording
            // `seq` restarts at 0 on every socket regardless of `resumed`. Frames sent on the
            // socket this one replaced and never acknowledged stay unacknowledged: their audio is
            // a gap uploaded over REST, never resent here.
            nextSeq = 0
            inFlight = [:]
            if !resumed {
                // A fresh bus — the first of the take, or one after the old bus is gone — opens
                // the same take again. Positions stay take-absolute across it, so nothing is
                // re-based: what was acknowledged before is stored, whichever bus stored it.
                try? await transport?.send(.gate(open: true, reason: "button", takeId: currentTakeId))
            }
            if wasReconnecting {
                dependencies.feedback(.reconnected)
            }
            await flushPending()
        case let .ack(throughSeq):
            dependencies.connectionEvent(.socketDelivered)
            let acked = inFlight.filter { $0.key <= throughSeq }
            guard !acked.isEmpty else { break }
            ackedRanges = TranscriptLedger.merge(ackedRanges + acked.values)
            inFlight = inFlight.filter { $0.key > throughSeq }
        case .clear:
            break
        case let .state(_, phase, _, _, silenceAllowed):
            lastNotice = phase == "listening" ? nil : lastNotice
            let wasWithholding = isWithholding
            if let output = gate?.setAllowed(silenceAllowed) {
                await sendGated(output, resumed: wasWithholding && !isWithholding)
            }
        case let .notice(severity, code, text):
            lastNotice = (severity, code, text)
            if code == VoiceNoticeCode.authExpired {
                lastDisconnectDetail = text
                await stopInternal(reason: .connectionLost)
            } else if severity == "warning" || severity == "error" {
                dependencies.feedback(.serverNotice(text))
            }
        case .ping:
            try? await transport?.send(.pong)
        case let .transcript(takeId, seq, isFinal, text, endSample):
            // A frame for another take — the previous one's tail on a reused bus — never lands
            // in this one.
            if let takeId, takeId != currentTakeId { break }
            highestAppliedSeq = max(highestAppliedSeq, seq)
            if isFinal {
                committedSegments.append(CommittedSegment(endSample: endSample ?? 0, seq: seq, text: text))
                currentPartial = ""
            } else {
                currentPartial = text
            }
        case let .takeDone(takeId, finalSeq, ended):
            guard takeId == currentTakeId else { break }
            lastTakeDone = (takeId, finalSeq, ended)
        case let .takeState(takeId, takeState, _, _):
            guard takeId == currentTakeId else { break }
            lastTakeState = takeState
        case .unrecognized:
            break
        }
    }

    /// Frames sent, keyed by their own `seq`, to the take samples they carried — what an `ack`
    /// resolves into `ackedRanges`. Pruned as acks arrive and cleared on every `ready`.
    private var inFlight: [Int: SampleRange] = [:]

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

    /// Hands one already-captured, already-durable-file-written buffer to the uplink. The caller
    /// resamples to the transport rate first and awaits each call from one consuming task, which
    /// is what keeps chunks in order. A chunk arriving while `canIngestAudio` is false is not
    /// sent (the recorder itself never stops — only this session's opinion about sending it
    /// changes), but it still counts as captured, so the seal covers the whole file.
    ///
    /// With a silence gate, every chunk goes through it first: a withheld chunk is neither sent
    /// nor queued, and counts as settled — recorded locally, never sent, never uploaded.
    public func ingestAudioChunk(pcm16le samples: [Int16], at offset: Int) async {
        guard state != .idle, !samples.isEmpty else { return }
        capturedUpTo = max(capturedUpTo, offset + samples.count)
        guard canIngestAudio else { return }
        let toSend = isMuted ? [Int16](repeating: 0, count: samples.count) : samples
        guard var gate else {
            await sendOrQueue(offset: offset, samples: toSend)
            return
        }
        let wasWithholding = gate.isWithholding
        let output = gate.push(offset: offset, samples: toSend)
        self.gate = gate
        await sendGated(output, resumed: wasWithholding && !gate.isWithholding)
    }

    /// Re-measures the room after the microphone changed, and tells the backend which one it is.
    public func inputRouteChanged() async {
        gate?.reset()
        guard state == .recording, let transport, let device = dependencies.device() else { return }
        try? await transport.send(.device(device))
    }

    private func sendGated(_ output: SilenceGate.Output, resumed: Bool) async {
        if resumed {
            let samples = output.send.reduce(0) { $0 + $1.samples.count }
            dependencies.log("gate resume preroll_ms=\(samples * 1000 / VoiceSocketProtocol.audioUplinkHz)")
        }
        for frame in output.send {
            await sendOrQueue(offset: frame.offset, samples: frame.samples)
        }
        // Only on a live socket: a `silence` decided while disconnected is never queued, since
        // the gate resets on the `ready` that ends the outage anyway.
        if let atSample = output.silenceAt, state == .recording, let transport {
            dependencies.log("gate withhold at_sample=\(atSample) mode=\(gate?.settings.mode.rawValue ?? "-")")
            try? await transport.send(.silence(atSample: atSample))
        }
    }

    private func sendOrQueue(offset: Int, samples: [Int16]) async {
        guard state == .recording, let transport else {
            pendingChunks.append((offset, samples))
            pendingSampleCount += samples.count
            let cap = Self.maxQueuedSeconds * VoiceSocketProtocol.audioUplinkHz
            while pendingSampleCount > cap, !pendingChunks.isEmpty {
                pendingSampleCount -= pendingChunks.removeFirst().samples.count
            }
            return
        }
        await send(offset: offset, samples: samples, transport: transport)
    }

    private func send(offset: Int, samples: [Int16], transport: any VoiceSocketTransportProtocol) async {
        let seq = nextSeq
        nextSeq += 1
        inFlight[seq] = offset..<(offset + samples.count)
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
        pendingSampleCount = 0
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

    /// The ordinary stop: closes the gate with the take's seal, then holds the socket open —
    /// answering pings, still receiving frames — until the take's receipt arrives, the deadline
    /// passes, the socket dies, or ``stopWaiting()`` is called, whichever comes first. Exits
    /// without waiting when there was no live connection in the first place: the seal then goes
    /// over REST, which is the caller's. `waitForReceipt: false` closes the gate and leaves at
    /// once — the person already said they are not waiting.
    public func stop(reason: RecordingEndReason = .user, waitForReceipt: Bool = true) async {
        guard state != .idle else { return }
        await stopInternal(reason: reason, waitForReceipt: waitForReceipt)
    }

    /// Ends the finishing wait now. Nothing is abandoned: the gate already carried the seal, and
    /// the server finishes the take whether or not this device is still listening.
    public func stopWaiting() {
        guard state == .stopping else { return }
        stopWaitingRequested = true
    }

    private func stopInternal(reason: RecordingEndReason, waitForReceipt: Bool = true) async {
        isStopping = true
        // Only `.recording` names a socket actually worth talking to — `.connecting`/
        // `.reconnecting`/`.paused` have no live gate to close and nothing to wait on.
        let wasConnected = state == .recording
        state = .stopping
        // Stopped while withholding: the ring goes out only if it caught the start of speech.
        // Without a socket it stays unsent, and so owed.
        let owed = gate?.stopFlush() ?? []
        if wasConnected, let transport {
            for frame in owed {
                await send(offset: frame.offset, samples: frame.samples, transport: transport)
            }
            try? await transport.send(
                .gate(
                    open: false, reason: "button", takeId: currentTakeId,
                    capturedSamples: currentTakeId == nil ? nil : capturedUpTo,
                    withheld: currentTakeId == nil ? nil : withheldRanges))
            if let takeId = currentTakeId, waitForReceipt {
                await self.waitForReceipt(takeId: takeId)
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

    /// Waits for the one positive signal there is — `take_done` for a live take, a `take_state`
    /// past `open` (the seal stored) for a batch one — never for a partial merely going quiet,
    /// which looks identical to a stalled connection.
    private func waitForReceipt(takeId: String) async {
        let deadlineAt = dependencies.now().addingTimeInterval(Self.finishingDeadlineSeconds)
        while true {
            switch sttMode {
            case .batch:
                if let lastTakeState, lastTakeState != .open { return }
            case .live, .unrecognized:
                if lastTakeDone?.takeId == takeId { return }
            }
            if socketDiedDuringStop || stopWaitingRequested { return }
            if dependencies.now() >= deadlineAt { return }
            await dependencies.sleep(.milliseconds(100))
        }
    }
}
