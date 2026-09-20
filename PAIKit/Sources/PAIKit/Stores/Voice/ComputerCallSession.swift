import Foundation
import Observation

/// Everything `ComputerCallSession` needs that this package cannot provide itself — same shape as
/// `VoiceUplinkDependencies`: closures read at call time, not values captured once.
public struct ComputerCallDependencies: Sendable {
    public var makeTransport: @Sendable () -> any VoiceSocketTransportProtocol
    public var socketURL: @Sendable () throws -> URL
    /// The bearer token this connection authenticates with — read fresh on every `hello`.
    public var authToken: @Sendable () -> String?
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Duration) async -> Void
    /// Where a drop, a recovery and an ending go — the same channel a dictation take reports on
    /// (`VoiceUplinkDependencies.feedback`), and for the same reason: a call is run with the
    /// phone in a pocket, so anything worth knowing has to reach Freddy without a screen.
    public var feedback: @Sendable (FeedbackEvent) -> Void

    public init(
        makeTransport: @escaping @Sendable () -> any VoiceSocketTransportProtocol,
        socketURL: @escaping @Sendable () throws -> URL,
        authToken: @escaping @Sendable () -> String?,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        feedback: @escaping @Sendable (FeedbackEvent) -> Void = { _ in }
    ) {
        self.makeTransport = makeTransport
        self.socketURL = socketURL
        self.authToken = authToken
        self.now = now
        self.sleep = sleep
        self.feedback = feedback
    }
}

/// Why the call could not even attempt a connection.
public enum ComputerCallStartFailure: Error, Sendable, Equatable {
    case notAuthenticated
    case malformedBackendURL
    case other(String)
}

extension ComputerCallStartFailure {
    public var userMessage: String {
        switch self {
        case .notAuthenticated: return "You're not signed in."
        case .malformedBackendURL: return "The backend address isn't configured correctly."
        case .other(let detail): return detail
        }
    }
}

/// Why a call ended — distinct from a mid-call drop (`ComputerCallConnectionState.reconnecting`),
/// which is not an ending at all.
public enum ComputerCallEndReason: Sendable, Equatable {
    case user
    case authExpired
    case connectionLost(reason: String?)
    /// The backend closed the transport itself — Computer said "end", or the idle timeout fired
    /// (`pai_cloud.computer.engine.ComputerEngine._maybe_finish_ending`/`_idle_watchdog`). A plain
    /// close with no prior `notice`, so there is no text to show beyond "the call ended".
    case serverClosed
}

/// Mirrors `VoiceUplinkReconnectPolicy` — every drop is retried, at a backoff that grows then
/// holds, whatever its reason. A live conversation is exactly the case where giving up after a
/// few attempts would be wrong: a dead patch of signal is ordinary, not fatal.
public enum ComputerCallReconnectPolicy {
    public static let backoffSeconds = [2, 4, 8, 16, 30]

    public static func delaySeconds(forAttempt attempt: Int) -> Int {
        let index = min(max(attempt, 1), backoffSeconds.count) - 1
        return backoffSeconds[index]
    }
}

public enum ComputerCallConnectionState: Sendable, Equatable {
    case idle
    case connecting
    case active
    case reconnecting
}

/// A direct conversation with Computer over `docs/VOICE_PROTOCOL.md`'s voice socket — the
/// switchboard's own root, not a take dictating into any session's draft. `hello` carries no
/// `draft_key`, which is what the backend's own `_build_engine` reads as "give this bus to
/// Computer" (`pai_cloud.voice.router`).
///
/// Unlike `VoiceUplinkSession`, this type holds no draft/take/ledger state at all — Computer's
/// own bus has no take boundary (`docs/VOICE_PROTOCOL.md`'s `gate` is client bookkeeping only
/// here; `ComputerEngine` never overrides `on_gate`). The one thing this session owns beyond the
/// socket itself is the downlink: a binary frame is Computer's own synthesized speech, handed to
/// `onAudioDown` for the app-side player, which reports back through `notePlayed(ref:)` once it
/// has genuinely finished rendering — the receipt the backend's own barge-in tracking depends on
/// (`docs/VOICE_PROTOCOL.md`: "the client cannot lie about having played something it has not").
///
/// `@MainActor` for the same reason `VoiceUplinkSession` is: a UI-driven view model, at an event
/// rate (a ping every 5s, an audio chunk every tens of ms) nowhere near where hopping onto the
/// main actor would cost anything.
@MainActor
@Observable
public final class ComputerCallSession {
    /// Comfortably above the backend's own 5s ping interval + 5s timeout — see
    /// `VoiceUplinkSession.watchdogTimeoutSeconds` for the same reasoning.
    static let watchdogTimeoutSeconds: TimeInterval = 12

    public private(set) var connectionState: ComputerCallConnectionState = .idle
    /// `.computer` until Computer connects this bus into a Kai session's own call mode (the
    /// switchboard, `docs/VOICE_PROTOCOL.md`'s opening paragraph) — never something this session
    /// requests, only something it is told about.
    public private(set) var busOwner: VoiceBusOwner = .computer
    /// Engine-internal (`listening`/`generating`/`speaking` under Computer; `wake`/`recording`/
    /// `sending` under a call this bus was switched into) — rendered, never acted on.
    public private(set) var phase: String = "listening"
    public private(set) var sessionId: String?
    public private(set) var lastNotice: (severity: String, code: String, text: String)?
    public private(set) var lastStartFailure: ComputerCallStartFailure?
    public private(set) var lastEndReason: ComputerCallEndReason?
    public private(set) var lastDisconnectDetail: String?

    /// One chunk of Computer's own synthesized speech to play, in `ref` order — the app hands
    /// this to its own player and calls `notePlayed(ref:)` once it has genuinely finished
    /// rendering, never when it is merely handed off.
    public var onAudioDown: (@Sendable (Int, Data) -> Void)?
    /// A barge-in: drop everything buffered for playback right now, without waiting for it to
    /// finish (`docs/VOICE_PROTOCOL.md`'s `clear`).
    public var onClearRequested: (@Sendable () -> Void)?

    private let dependencies: ComputerCallDependencies
    private var transport: (any VoiceSocketTransportProtocol)?
    private var receiveTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    /// This socket's own frame counter — restarts at 0 on EVERY `ready`, fresh bus or resumed
    /// alike (`docs/VOICE_PROTOCOL.md`, "Framing": `seq` is scoped to this client connection,
    /// never to the bus, and always restarts at 0 on the reconnected socket even when
    /// `ready.resumed` is `true`). Computer keeps no `inFlight`/ack-watermark table to prune
    /// alongside it, unlike `VoiceUplinkSession` — nothing here reads an ack at all.
    private var nextSeq = 0
    private var sampleOffset = 0
    private var resumeToken: String?
    /// Whether this bus has already had its gate opened once. `ComputerEngine` ignores `on_gate`
    /// entirely, so re-sending it on every reconnect would be harmless — this still tracks it,
    /// matching the protocol's general contract that a client only opens a gate once per take,
    /// and because a future engine attached to this same bus (the switchboard) might not be so
    /// forgiving.
    private var hasOpenedGate = false
    private var lastReceiveAt: Date?
    private var isStopping = false
    /// Whether the `ready` about to arrive is closing a drop rather than opening a fresh call —
    /// read once and cleared, so a reconnect that itself drops again announces each recovery
    /// exactly once. `connectionState` cannot answer this: `ready` sets it to `.active` before
    /// anything downstream could read what it was.
    private var wasReconnecting = false

    public init(dependencies: ComputerCallDependencies) {
        self.dependencies = dependencies
    }

    public var canStart: Bool { connectionState == .idle }

    // MARK: - Start

    public func start() async {
        guard connectionState == .idle else { return }
        lastStartFailure = nil
        lastEndReason = nil
        lastDisconnectDetail = nil
        lastNotice = nil
        nextSeq = 0
        sampleOffset = 0
        resumeToken = nil
        hasOpenedGate = false
        reconnectAttempt = 0
        isStopping = false
        wasReconnecting = false
        busOwner = .computer
        phase = "listening"
        sessionId = nil

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

        connectionState = .connecting
        await connect(url: url, token: token)
    }

    // MARK: - Connect / reconnect

    private func connect(url: URL, token: String) async {
        let transport = dependencies.makeTransport()
        self.transport = transport
        do {
            try await transport.connect(url: url)
            try await transport.send(
                .hello(
                    transport: VoiceSocketProtocol.transportName,
                    caps: VoiceSocketCapabilities(audioDownlink: true, dtmf: false),
                    auth: token,
                    resumeToken: resumeToken,
                    draftKey: nil
                )
            )
        } catch {
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
            case let .audio(ref, pcm):
                onAudioDown?(ref, pcm)
            case let .control(frame):
                await handle(frame)
            }
        }
    }

    private func handle(_ frame: VoiceDownFrame) async {
        switch frame {
        case let .ready(newResumeToken, owner, resumed, sessId):
            resumeToken = newResumeToken
            reconnectAttempt = 0
            busOwner = owner
            sessionId = sessId
            connectionState = isStopping ? connectionState : .active
            // `seq` restarts at 0 on every socket regardless of `resumed` — see this type's own
            // `nextSeq` doc comment.
            nextSeq = 0
            if !resumed {
                sampleOffset = 0
                hasOpenedGate = false
            }
            if !hasOpenedGate {
                hasOpenedGate = true
                try? await transport?.send(.gate(open: true, reason: "button"))
            }
            if wasReconnecting {
                wasReconnecting = false
                dependencies.feedback(.reconnected)
            }
        case .ack:
            // Computer's own delivery has no draft region to gate on — nothing here reads an
            // ack watermark, unlike `VoiceUplinkSession`.
            break
        case .clear:
            onClearRequested?()
        case let .state(owner, ph, sessId, _):
            busOwner = owner
            phase = ph
            sessionId = sessId
        case let .notice(severity, code, text):
            lastNotice = (severity, code, text)
            if code == VoiceNoticeCode.authExpired {
                lastDisconnectDetail = text
                dependencies.feedback(.callEndedUnexpectedly(hadUnsentText: false))
                await stopInternal(reason: .authExpired)
            } else if severity == "warning" || severity == "error" {
                dependencies.feedback(.serverNotice(text))
            }
        case .ping:
            try? await transport?.send(.pong)
        case .transcript:
            // This session always declares an audio downlink — a `transcript` frame is never
            // sent to a transport that did.
            break
        case .unrecognized:
            break
        }
    }

    private func handleConnectionLost(detail: String?) async {
        guard connectionState != .idle, !isStopping else { return }
        stopWatchdog()
        lastDisconnectDetail = detail
        // A normal WebSocket closure (code 1000) is the backend closing this transport on
        // purpose — Computer said "end", the idle timeout fired, or another device took over
        // this bus — never something to reconnect past. `URLSessionVoiceSocketTransport`'s own
        // `closeDescription` is the only place that distinction survives once `receive()` has
        // already thrown; an ordinary network drop never carries a close code at all.
        if let detail, detail.hasPrefix("close 1000") {
            // Ending a call from this side never reaches here — `stopInternal` sets `isStopping`
            // first and this method returns on it — so a clean close arriving here is always one
            // Freddy did not ask for, and the one he is least likely to be looking at the screen
            // for. `hadUnsentText` is false because nothing here can know: a call's dictation
            // lives in the session's own draft, which this type has no view of.
            dependencies.feedback(.callEndedUnexpectedly(hadUnsentText: false))
            await stopInternal(reason: .serverClosed)
            return
        }
        connectionState = .reconnecting
        wasReconnecting = true
        dependencies.feedback(.connectionDropped(reason: detail))
        await scheduleReconnect(reason: detail ?? "connection lost")
    }

    private func scheduleReconnect(reason: String) async {
        guard !isStopping else { return }
        reconnectAttempt += 1
        let delaySeconds = ComputerCallReconnectPolicy.delaySeconds(forAttempt: reconnectAttempt)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            await self.dependencies.sleep(.seconds(delaySeconds))
            guard !Task.isCancelled else { return }
            await self.attemptReconnect()
        }
    }

    private func attemptReconnect() async {
        guard !isStopping, connectionState != .idle else { return }
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
    /// carrying anything without ever throwing.
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

    // MARK: - Uplink audio

    /// One already-captured buffer of mono 16kHz PCM16 samples, resampled by the caller — never
    /// this type's own concern, matching `VoiceUplinkSession.ingestAudioChunk`'s contract.
    /// Dropped while not `.active`: unlike a dictation take, nothing here archives what was said
    /// during a brief drop, so there is nothing to backfill later.
    public func sendMicChunk(pcm16le samples: [Int16]) async {
        guard connectionState == .active, let transport, !samples.isEmpty else { return }
        let seq = nextSeq
        nextSeq += 1
        let offset = sampleOffset
        sampleOffset += samples.count
        let frame = VoiceSocketProtocol.packUplinkAudio(seq: seq, sampleOffset: offset, pcm16le: samples)
        try? await transport.sendAudio(frame)
    }

    // MARK: - Controls

    /// One of the controls a call's own spoken grammar offers, sent as a frame instead of said
    /// out loud. Dropped while this bus is not inside a session's call mode: Computer's own
    /// engine has nothing to do with any of them, so a frame sent there would be a button that
    /// silently did nothing rather than one the screen never offered.
    public func send(command: VoiceCallCommand) async {
        guard connectionState == .active, busOwner == .call, let transport else { return }
        try? await transport.send(.command(command))
    }

    // MARK: - Downlink playback receipt

    /// The app-side player finished actually rendering the chunk carrying `ref` — forwarded as
    /// the protocol's own `played` frame, which is what lets the backend's two-state playback
    /// tracking know this audio is genuinely audible rather than merely sent.
    public func notePlayed(ref: Int) async {
        guard let transport else { return }
        try? await transport.send(.played(ref: ref))
    }

    // MARK: - End

    public func end(reason: ComputerCallEndReason = .user) async {
        guard connectionState != .idle else { return }
        await stopInternal(reason: reason)
    }

    /// The backend closed the transport on its own (Computer said "end", or the idle timeout) —
    /// the receive loop's `catch` reports this exactly like any other connection loss, so this
    /// session cannot tell "Computer hung up" apart from "the network dropped" from the error
    /// alone. A caller that wants to distinguish them reads `phase`/`lastNotice` first.
    private func stopInternal(reason: ComputerCallEndReason) async {
        isStopping = true
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
        connectionState = .idle
        isStopping = false
    }
}
