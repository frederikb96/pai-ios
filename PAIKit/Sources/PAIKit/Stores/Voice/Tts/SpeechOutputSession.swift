import Foundation
import Observation

/// Everything `SpeechOutputSession` needs that this package cannot provide itself — the TTS
/// counterpart to `VoiceRecordingDependencies`, same reasoning: closures read at call time, a
/// fake clock and instant sleep for tests, real ones in production.
public struct SpeechOutputDependencies: Sendable {
    public var mintToken: @Sendable (VoiceTokenPurpose) async throws -> VoiceToken
    public var makeTransport: @Sendable () -> VoiceTtsTransport
    /// Freddy's pasted ElevenLabs voice id — read at connect time, not captured once, so
    /// changing it in settings takes effect on the next reply rather than needing the call
    /// restarted.
    public var voiceId: @Sendable () -> String
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Duration) async -> Void
    /// The one thing this package cannot do itself — turn decoded, normalised PCM samples into
    /// sound. `SpeechOutput` (app target) is the only production implementation; a test supplies
    /// a spy instead.
    public var playAudio: @Sendable ([Float]) -> Void
    /// Stops whatever is currently playing and drops anything scheduled but not yet heard —
    /// "computer skip"'s audible half.
    public var stopPlayback: @Sendable () -> Void
    public var feedback: @Sendable (FeedbackEvent) -> Void

    public init(
        mintToken: @escaping @Sendable (VoiceTokenPurpose) async throws -> VoiceToken,
        makeTransport: @escaping @Sendable () -> VoiceTtsTransport,
        voiceId: @escaping @Sendable () -> String,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        playAudio: @escaping @Sendable ([Float]) -> Void = { _ in },
        stopPlayback: @escaping @Sendable () -> Void = {},
        feedback: @escaping @Sendable (FeedbackEvent) -> Void = { _ in }
    ) {
        self.mintToken = mintToken
        self.makeTransport = makeTransport
        self.voiceId = voiceId
        self.now = now
        self.sleep = sleep
        self.playAudio = playAudio
        self.stopPlayback = stopPlayback
        self.feedback = feedback
    }
}

/// How long `SpeechOutputSession` waits before retrying a mint or a reconnect, and how many times
/// it retries speaking the SAME reply before giving up on it. Unlike STT's take, a TTS drop never
/// has to end anything — there is no live capture to lose — so what would otherwise be an
/// unbounded retry is bounded per reply instead: without a cap, one reply on a badly broken link
/// would silently block everything queued behind it for the rest of the call.
enum TtsReconnectPolicy {
    static let backoffSeconds = [2, 4, 8, 16, 30]
    static let maxResendsPerReply = 3

    static func delaySeconds(forAttempt attempt: Int) -> Int {
        let index = min(max(attempt, 1), backoffSeconds.count) - 1
        return backoffSeconds[index]
    }
}

public enum SpeechOutputState: Sendable, Equatable {
    case idle
    case connecting
    case speaking(contextId: String, messageId: Int)
}

/// Drives ElevenLabs' multi-context TTS socket end to end: mint a token, connect, open one
/// context per queued reply, stream its sentences, play back what comes over the wire, and — on
/// a drop — reconnect and resume the reply in flight rather than losing or duplicating the whole
/// call. Everything a real audio graph would otherwise supply (decoded samples going somewhere
/// audible) arrives through `SpeechOutputDependencies.playAudio`, which is what makes every
/// branch here reachable from a unit test.
///
/// One socket serves the whole call rather than one per reply: the socket is left open between
/// replies instead of being proactively closed, and reconnects lazily — on the next `enqueue` or
/// on the receive loop's own error — rather than being kept alive with a dedicated idle context.
/// ElevenLabs documents no connection-level (as opposed to per-context) inactivity behaviour for
/// this endpoint, so holding a context open purely to prevent a timeout would be built against a
/// guess; reconnecting when there is actually a reply to speak is not.
///
/// `@MainActor` for the same reason `VoiceRecordingSession` is: every realistic caller is a
/// UI-driven view model, and the event rate (one context per reply, a handful of audio chunks a
/// second) is nowhere near where hopping onto the main actor would cost anything.
@MainActor
@Observable
public final class SpeechOutputSession {
    public private(set) var state: SpeechOutputState = .idle
    public private(set) var queue = ReplyQueue()
    /// Recent stretches of audio this session actually sent to the transport for playback,
    /// wall-clock-stamped with the reply text that was playing — what `EchoWindowRejection`
    /// compares a command's own word-time window against once the caller has converted it to
    /// wall clock. Pruned to the last minute; a command observation arrives within a second or
    /// two of the audio it might be echoing, never later.
    public private(set) var recentPlayback: [(window: ClosedRange<Date>, text: String)] = []

    private let dependencies: SpeechOutputDependencies
    private var transport: VoiceTtsTransport?
    private var receiveTask: Task<Void, Never>?
    private var currentContextId: String?
    private var resendsForCurrentReply = 0
    private var openPlaybackStart: Date?
    private var openPlaybackText = ""
    /// Total PCM duration of every audio chunk received for the currently open context —
    /// measured against a live socket, ElevenLabs generates and delivers audio far ahead of
    /// playback (11.7s of audio arrived in five chunks within about a second, well before
    /// `close_context` was even sent), so the *audible* end of a reply is nowhere near when its
    /// last byte was received. This is what lets `finalizeOpenPlayback` compute the actual
    /// playback window from PCM duration instead of from receipt timing.
    private var openPlaybackAccumulatedDuration: TimeInterval = 0
    private var ended = false

    private static let playbackHorizonSeconds: TimeInterval = 60
    /// `VoiceTtsProtocol.outputFormat`'s rate — the divisor for turning a chunk's sample count
    /// into the seconds of audio it actually represents.
    private static let sampleRateHz: Double = 24000

    public init(dependencies: SpeechOutputDependencies) {
        self.dependencies = dependencies
    }

    /// A reply arrived — appended to the queue; speaking starts (minting and connecting first if
    /// there is no socket yet) unless something else is already in flight, in which case the
    /// existing head keeps playing and this one waits its turn.
    public func enqueue(messageId: Int, sentences: [String]) {
        let wasIdle = state == .idle
        queue.enqueue(messageId: messageId, sentences: sentences)
        // Claims `state` synchronously, before the `Task` below ever runs — two `enqueue` calls
        // in a row (no `await` between them) would otherwise both see `.idle` and both dispatch
        // a connect, since `MainActor` only serialises across suspension points, not around a
        // `Task {}` that starts one.
        guard wasIdle else { return }
        state = .connecting
        Task { await self.advance() }
    }

    /// "computer skip" — silences whatever is playing immediately, closes its context, drops it
    /// from the queue, and starts the next reply if there is one.
    public func skip() {
        dependencies.stopPlayback()
        finalizeOpenPlayback(interrupted: true)
        guard queue.dropHead() != nil else { return }
        resendsForCurrentReply = 0
        let contextIdToClose = currentContextId
        currentContextId = nil
        // Same synchronous claim as `enqueue`: only `.idle` when there is genuinely nothing left
        // to advance to, so a concurrent `enqueue` can never race this skip's own `advance()`.
        state = queue.isEmpty ? .idle : .connecting
        Task {
            if let contextIdToClose { await self.sendFrame(.closeContext(contextId: contextIdToClose)) }
            await self.advance()
        }
    }

    /// Ends this session's speech output for the call — closes the socket, drops anything still
    /// queued unspoken. Nothing here restarts on its own after this; a fresh call needs a fresh
    /// `SpeechOutputSession`.
    public func end() {
        ended = true
        receiveTask?.cancel()
        dependencies.stopPlayback()
        finalizeOpenPlayback(interrupted: true)
        let transportToClose = transport
        transport = nil
        currentContextId = nil
        queue = ReplyQueue()
        state = .idle
        Task { await transportToClose?.close(code: 1000, reason: nil) }
    }

    // MARK: - Driving the queue

    /// Ensures the head of the queue is being spoken: connects if there is no socket yet, opens
    /// a fresh context if the head has no context open, and (re)sends whatever of its sentences
    /// have not yet been handed to the transport.
    private func advance() async {
        guard !ended, let head = queue.head else {
            state = .idle
            return
        }

        if transport == nil {
            state = .connecting
            do {
                let token = try await dependencies.mintToken(.tts)
                guard let url = VoiceTtsProtocol.connectionURL(voiceId: dependencies.voiceId(), token: token.token)
                else {
                    await handleReplyFailure(reason: "invalid TTS connection URL")
                    return
                }
                let newTransport = dependencies.makeTransport()
                try await newTransport.connect(url: url)
                transport = newTransport
                startReceiveLoop()
            } catch {
                await handleReplyFailure(reason: "\(error)")
                return
            }
        }

        let contextId = currentContextId ?? UUID().uuidString
        currentContextId = contextId
        state = .speaking(contextId: contextId, messageId: head.messageId)

        let sentencesToSend = head.remaining
        guard !sentencesToSend.isEmpty else {
            // Every sentence was already handed to the transport before a drop; the reply is
            // fully in flight and this call is just waiting on its audio to keep arriving.
            return
        }

        await sendFrame(.initializeContext(contextId: contextId))
        for (index, sentenceText) in sentencesToSend.enumerated() {
            let isLast = index == sentencesToSend.count - 1
            await sendFrame(.sendText(contextId: contextId, text: sentenceText + " ", flush: isLast))
            queue.recordSentencesSent()
        }
    }

    /// A reply could not even be started (mint or connect failed) or the socket dropped while it
    /// was in flight — retried up to `TtsReconnectPolicy.maxResendsPerReply` times on a fresh
    /// context before the reply is abandoned so the queue is not starved by one broken reply.
    private func handleReplyFailure(reason: String) async {
        guard !ended else { return }
        transport = nil
        currentContextId = nil
        // Whatever had already played for the dropped context is a real, finished playback
        // window — recorded now rather than left open, so a fresh context's audio (after this
        // reconnects) starts its own window instead of silently extending this one across the
        // gap the drop just opened.
        finalizeOpenPlayback(interrupted: true)
        dependencies.feedback(.ttsDropped)

        guard !queue.isEmpty else {
            state = .idle
            return
        }

        resendsForCurrentReply += 1
        guard resendsForCurrentReply <= TtsReconnectPolicy.maxResendsPerReply else {
            dependencies.feedback(.replyNotSpoken)
            queue.dropHead()
            resendsForCurrentReply = 0
            await advance()
            return
        }

        state = .connecting
        let delay = TtsReconnectPolicy.delaySeconds(forAttempt: resendsForCurrentReply)
        await dependencies.sleep(.seconds(delay))
        guard !ended else { return }
        await advance()
    }

    // MARK: - Receiving

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }
    }

    private func receiveLoop() async {
        while !ended {
            guard let transport else { return }
            do {
                let text = try await transport.receive()
                handle(TtsDownlinkMessage.decode(text))
            } catch {
                guard !ended else { return }
                await handleReplyFailure(reason: "\(error)")
                return
            }
        }
    }

    private func handle(_ message: TtsDownlinkMessage?) {
        switch message {
        case .audio(let contextId, let base64):
            guard contextId == nil || contextId == currentContextId else { return }
            guard let samples = VoiceTtsProtocol.floatSamples(fromBase64: base64) else { return }
            if openPlaybackStart == nil {
                openPlaybackStart = dependencies.now()
                openPlaybackText = queue.head?.sentences.joined(separator: " ") ?? ""
            }
            openPlaybackAccumulatedDuration += Double(samples.count) / Self.sampleRateHz
            dependencies.playAudio(samples)

        case .contextFinished(let contextId):
            guard contextId == nil || contextId == currentContextId else { return }
            // Not interrupted: every chunk for this context has now arrived, so the natural end
            // — `start + openPlaybackAccumulatedDuration` — is when playback actually finishes,
            // even though that is well after this message itself arrived.
            finalizeOpenPlayback(interrupted: false)
            queue.completeHead()
            currentContextId = nil
            resendsForCurrentReply = 0
            Task { await self.advance() }

        case .unrecognized, nil:
            break
        }
    }

    // MARK: - Playback bookkeeping

    /// `interrupted` is `false` only when every chunk for the context actually arrived
    /// (`.contextFinished`) — then the window runs to its natural end,
    /// `start + openPlaybackAccumulatedDuration`, which is almost always well after this call
    /// itself happens, since ElevenLabs generates audio far ahead of when it is actually heard.
    /// `true` (skip, a drop, or the call ending) caps the window at `now()` instead: playback was
    /// cut short before whatever had already arrived finished playing.
    private func finalizeOpenPlayback(interrupted: Bool) {
        guard let start = openPlaybackStart else { return }
        let naturalEnd = start.addingTimeInterval(openPlaybackAccumulatedDuration)
        let end = interrupted ? min(dependencies.now(), naturalEnd) : naturalEnd
        let window = start <= end ? start...end : start...start
        recentPlayback.append((window: window, text: openPlaybackText))
        openPlaybackStart = nil
        openPlaybackAccumulatedDuration = 0
        openPlaybackText = ""
        let horizon = dependencies.now().addingTimeInterval(-Self.playbackHorizonSeconds)
        recentPlayback.removeAll { $0.window.upperBound < horizon }
    }

    private func sendFrame(_ message: TtsUplinkMessage) async {
        guard let transport else { return }
        guard let data = try? message.encoded() else { return }
        try? await transport.send(text: String(decoding: data, as: UTF8.self))
    }
}
