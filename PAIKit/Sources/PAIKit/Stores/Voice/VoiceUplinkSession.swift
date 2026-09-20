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
    /// Whether this take's own `take_id` has already ridden a `gate open` once — see the `.ready`
    /// handler's own comment for why only the FIRST one carries it.
    private var hasOpenedGateForCurrentTake = false
    private var recordingStart: Date?
    private var mutedMs = 0
    private var lastMuteToggle: Date?
    private var lastReceiveAt: Date?
    private var isStopping = false
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
        hasOpenedGateForCurrentTake = false
        recordingStart = dependencies.now()
        reconnectAttempt = 0
        isStopping = false
        pendingChunks = []

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
                // transcribed from here is silently dropped (`DraftRegionSink.deliver` no-ops
                // with no `start_take()` behind it). A fresh bus also means the ack watermark
                // reset to nothing on the server's side; resume sending from wherever local
                // delivery is actually confirmed, so nothing already acked is resent, but
                // nothing captured since is skipped either.
                ackedUpTo = 0
                // `takeId` rides only on the FIRST open of this take, deliberately not on a later
                // reopen — now a decision made WITH `resumed` in hand, not a guess forced by not
                // having it. The backend mints a fresh region for a take_id it has never seen,
                // which is safe by construction (`write_draft_region`'s stale-seq guard only
                // ever compares against a row that already exists) — but re-sending the SAME
                // take_id on a reopen that already delivered live text would hand the fresh
                // engine's own reset `seq` (0, 1, 2, …) to a region whose stored `seq` is already
                // higher, and every further word would silently no-op against that guard rather
                // than actually reaching the draft. `resumed` tells this client the bus/engine
                // identity, not whether `write_draft_region`'s own guard has been made tolerant
                // of that reset — nothing server-side has changed on that front — so a genuinely
                // fresh bus (`resumed == false`) still gets a fresh region for the recovered
                // continuation: a real, accepted, previously-reported limitation, not a
                // regression from this fix.
                let takeId = hasOpenedGateForCurrentTake ? nil : currentTakeId
                hasOpenedGateForCurrentTake = true
                try? await transport?.send(.gate(open: true, reason: "button", takeId: takeId))
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
                await stopInternal(reason: .connectionLost)
            } else if severity == "warning" || severity == "error" {
                dependencies.feedback(.serverNotice(text))
            }
        case .ping:
            try? await transport?.send(.pong)
        case .transcript:
            // This session always declares an audio downlink — a `transcript` frame is never sent
            // to a transport that did (`docs/VOICE_PROTOCOL.md`). Ignored rather than asserted:
            // an assertion here would crash a live take over a backend that changed its mind about
            // this transport's own declared capabilities.
            break
        case .unrecognized:
            break
        }
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

    public func stop(reason: RecordingEndReason = .user) async {
        guard state != .idle else { return }
        await stopInternal(reason: reason)
    }

    private func stopInternal(reason: RecordingEndReason) async {
        isStopping = true
        state = .stopping
        stopWatchdog()
        reconnectTask?.cancel()
        receiveTask?.cancel()
        if let transport {
            try? await transport.send(.gate(open: false, reason: "button"))
            try? await transport.send(.bye(reason: "stop"))
            await transport.close(code: 1000, reason: "stop")
        }
        transport = nil
        lastEndReason = reason
        state = .idle
        isStopping = false
    }
}
