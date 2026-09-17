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
    /// One chunk of normalised, decoded PCM for `messageId`'s reply, in the order it should be
    /// heard. `SpeechOutput` (app target) is the only production implementation — schedules it
    /// onto the player; a test supplies a spy instead. Never called for a reply before it is its
    /// turn to play: audio for anything still queued behind the reply currently playing is held
    /// inside this session instead, which is what lets `stopPlayback()` silence exactly one
    /// reply's audio and nothing queued after it.
    public var playAudio: @Sendable (_ messageId: Int, _ samples: [Float]) -> Void
    /// No more audio is coming for `messageId` — every chunk this session will ever hand to
    /// `playAudio` for it has already been sent. `SpeechOutput` attaches a completion handler to
    /// whichever scheduled buffer this makes the last one for `messageId`, and reports back
    /// through `SpeechOutputSession.playbackFinished(messageId:)` once that buffer has actually
    /// finished rendering — not when it was merely scheduled, which a live socket probe showed
    /// can be seconds to minutes earlier.
    public var markReplyAudioComplete: @Sendable (_ messageId: Int) -> Void
    /// Stops whatever is currently playing and drops anything scheduled but not yet heard for
    /// the reply that is currently live — "computer skip"'s audible half. Never touches audio for
    /// a later reply, because a later reply's audio is never handed to `playAudio` until it is
    /// its own turn to play.
    public var stopPlayback: @Sendable () -> Void
    public var feedback: @Sendable (FeedbackEvent) -> Void
    /// A diagnostics line for the socket's own lifecycle — defaults to discarding everything, so
    /// a caller that never wires a real sink (a test, or an app build that has not connected one
    /// yet) pays nothing for it. Same shape as `CallModeDependencies.log`.
    public var log: @Sendable (VoiceLogLevel, String, String) -> Void

    public init(
        mintToken: @escaping @Sendable (VoiceTokenPurpose) async throws -> VoiceToken,
        makeTransport: @escaping @Sendable () -> VoiceTtsTransport,
        voiceId: @escaping @Sendable () -> String,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        playAudio: @escaping @Sendable (_ messageId: Int, _ samples: [Float]) -> Void = { _, _ in },
        markReplyAudioComplete: @escaping @Sendable (_ messageId: Int) -> Void = { _ in },
        stopPlayback: @escaping @Sendable () -> Void = {},
        feedback: @escaping @Sendable (FeedbackEvent) -> Void = { _ in },
        log: @escaping @Sendable (VoiceLogLevel, String, String) -> Void = { _, _, _ in }
    ) {
        self.mintToken = mintToken
        self.makeTransport = makeTransport
        self.voiceId = voiceId
        self.now = now
        self.sleep = sleep
        self.playAudio = playAudio
        self.markReplyAudioComplete = markReplyAudioComplete
        self.stopPlayback = stopPlayback
        self.feedback = feedback
        self.log = log
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

/// How often `SpeechOutputSession` pings its dedicated idle context, well inside
/// `VoiceTtsProtocol.maxInactivityTimeoutSeconds` — a wide margin rather than one close to the
/// ceiling, since nothing here is time-critical and a single delayed tick must never itself risk
/// crossing the timeout.
enum TtsKeepAlivePolicy {
    static let intervalSeconds = 60
}

public enum SpeechOutputState: Sendable, Equatable {
    case idle
    /// The socket is connecting, or a reply is being generated with nothing audible yet — the
    /// wire and playback are deliberately decoupled (see the type's own doc comment), so this
    /// covers both "not connected yet" and "generating ahead of what is currently playing".
    case connecting
    /// `messageId` is the reply actually audible right now — never the one merely being
    /// generated, which a live socket probe showed can race seconds to minutes ahead of it.
    case speaking(messageId: Int)
}

/// Drives ElevenLabs' multi-context TTS socket end to end: mint a token, connect, generate one
/// reply's audio after another, and play them back in order — reconnecting and resuming a reply
/// in flight on a drop rather than losing or duplicating anything.
///
/// **Generation and playback are two separate pipelines, deliberately.** A live socket probe
/// measured ElevenLabs delivering a whole reply's audio — and marking it finished — far ahead of
/// when a person would actually finish hearing it (11.7s of audio arrived within about a second).
/// `queue`/`currentContextId` track what is being *generated*, advancing the moment a context
/// reports finished so the next reply can start generating immediately (pipelining, for
/// latency). `currentlyPlayingMessageId`/`readyToPlay`/`buffered` track what is actually
/// *audible*: a reply's audio is only ever handed to `dependencies.playAudio` once it is that
/// reply's turn to play — audio that arrives for a later reply while an earlier one is still
/// playing is held here instead. That split is what makes `skip()` interrupt exactly the reply
/// being heard: `dependencies.stopPlayback()` only ever has one reply's buffers scheduled in the
/// player to begin with, so it can never eat a later reply's audio the way silencing the player
/// while several replies' worth of audio sit scheduled at once would.
///
/// One socket serves the whole call rather than one per reply: the socket is left open between
/// replies instead of being proactively closed. ElevenLabs closes the whole connection — every
/// context on it, not just one — after `VoiceTtsProtocol.maxInactivityTimeoutSeconds` of no
/// activity anywhere on it; requesting that ceiling on connect buys headroom, but a call sits
/// quiet between replies for far longer than even that on an ordinary ride, so this session pings
/// a context opened purely to stay open (`keepAliveTick()`) on `TtsKeepAlivePolicy`'s own
/// schedule. A genuine network loss still reconnects lazily — on the next `enqueue` or on the
/// receive loop's own error — exactly as before; only a silence-driven close is now prevented
/// rather than treated as a drop.
///
/// `@MainActor` for the same reason `VoiceRecordingSession` is: every realistic caller is a
/// UI-driven view model, and the event rate (one context per reply, a handful of audio chunks a
/// second) is nowhere near where hopping onto the main actor would cost anything.
@MainActor
@Observable
public final class SpeechOutputSession {
    public private(set) var state: SpeechOutputState = .idle
    public private(set) var queue = ReplyQueue()
    /// Recent stretches of audio actually heard, wall-clock-stamped with the reply text that was
    /// playing — what `EchoWindowRejection` compares a command's own word-time window against
    /// once the caller has converted it to wall clock. Stamped from `playbackFinished(messageId:)`
    /// (or an interruption), never from when audio merely arrived from the wire, which a live
    /// socket probe showed can be seconds to minutes earlier. Pruned to the last minute.
    public private(set) var recentPlayback: [(window: ClosedRange<Date>, text: String)] = []

    private let dependencies: SpeechOutputDependencies
    private var transport: VoiceTtsTransport?
    private var receiveTask: Task<Void, Never>?
    private var currentContextId: String?
    private var resendsForCurrentReply = 0
    private var ended = false
    /// Set once ElevenLabs has rejected the request itself (`TtsDownlinkMessage.serverError`) —
    /// an unknown voice id, a bad or missing key. Sticky for the rest of this session: every
    /// future reply would hit the identical rejection, so nothing here ever attempts to connect
    /// again once this is true, matching `VoiceRecordingSession.stopTranscriptionAttempts`'s own
    /// "this is not the kind of failure a retry fixes" handling for the STT side.
    private var rejected = false
    /// Set the instant a drop is detected, cleared the instant a context afterward actually gets
    /// content onto the wire — what tells `advance()` when to emit `.ttsReconnected`, the health
    /// episode `.ttsDropped` opens (`FeedbackPolicy` shares one episode across every connection
    /// event) has no other way to close in a call with no STT socket of its own to close it for.
    private var recoveringFromDrop = false
    /// A context opened purely to stay open, so `keepAliveTick()` has something to ping across a
    /// stretch with no reply context of its own. `nil` until the first tick that actually needs
    /// it (a short call may never open one at all), and reset to `nil` whenever the transport it
    /// belongs to goes away — a stale id pinged on a fresh socket references a context that was
    /// never opened on it.
    private var keepAliveContextId: String?
    private var keepAliveTask: Task<Void, Never>?

    // MARK: Playback pipeline — see the type's own doc comment for why this is separate from
    // `queue`/`currentContextId` above.

    /// One reply's audio, accumulated while it waits its turn to play (or, for the reply
    /// currently playing, retained only for its `text` and `generationFinished` flag — its
    /// chunks are handed to `playAudio` immediately instead of sitting here).
    private struct BufferedReply {
        var chunks: [[Float]] = []
        var text: String
        var generationFinished = false
    }
    private var buffered: [Int: BufferedReply] = [:]
    /// Message ids whose generation has finished and which are waiting for their turn to play, in
    /// the order they finished generating — always the order they should play in too, since
    /// generation itself is serialised one context at a time.
    private var readyToPlay: [Int] = []
    private var currentlyPlayingMessageId: Int?
    private var playbackStart: [Int: Date] = [:]

    private static let playbackHorizonSeconds: TimeInterval = 60

    public init(dependencies: SpeechOutputDependencies) {
        self.dependencies = dependencies
        startKeepAliveTimer()
    }

    /// Runs for the whole session lifetime, not just while a socket happens to be open —
    /// `keepAliveTick()` itself no-ops whenever there is nothing to ping, so there is nothing to
    /// start or stop per connection. Real `Task.sleep`, not `dependencies.sleep`: that dependency
    /// exists for the bounded, finite-count backoff in `handleReplyFailure`, and an unbounded loop
    /// built on its test double (an instant no-op) would spin the main actor rather than wait.
    private func startKeepAliveTimer() {
        keepAliveTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(TtsKeepAlivePolicy.intervalSeconds))
                guard let self, !Task.isCancelled else { return }
                await self.keepAliveTick()
            }
        }
    }

    /// One keep-alive step: pings a dedicated idle context, opening it first if this is the first
    /// time it is actually needed. A no-op whenever something else already resets ElevenLabs'
    /// connection-wide inactivity clock on its own — no live socket, or a reply's own context
    /// already doing it — so calling this never has a visible effect beyond the wire traffic
    /// itself. Left internal rather than private so a test can drive it directly, simulating many
    /// idle intervals passing without an actual wait.
    func keepAliveTick() async {
        guard !ended, transport != nil, queue.isEmpty else { return }
        if keepAliveContextId == nil {
            let contextId = UUID().uuidString
            keepAliveContextId = contextId
            dependencies.log(.debug, "tts", "keep-alive context opened")
            await sendFrame(.initializeContext(contextId: contextId))
        }
        guard let contextId = keepAliveContextId else { return }
        dependencies.log(.debug, "tts", "keep-alive ping")
        await sendFrame(.keepContextAlive(contextId: contextId))
    }

    /// A reply arrived — appended to the queue; generation starts (minting and connecting first
    /// if there is no socket yet) unless something else is already generating, in which case this
    /// one waits its turn on the wire the same way it will for playback.
    public func enqueue(messageId: Int, sentences: [String]) {
        guard !rejected else {
            dependencies.log(.info, "tts", "reply \(messageId) not spoken — voice rejected earlier this call")
            dependencies.feedback(.replyNotSpoken)
            return
        }
        dependencies.log(.info, "tts", "reply \(messageId) enqueued (\(sentences.count) sentences)")
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

    /// "computer skip" — silences whatever is actually playing immediately and moves on to
    /// whatever is next, whether that next reply has already finished generating (the common
    /// case, since ElevenLabs generates far ahead of playback) or is still being sent.
    ///
    /// The silencing is entirely `dependencies.stopPlayback()`, called first and synchronously:
    /// a live socket probe showed ElevenLabs generating audio far ahead of playback, so by the
    /// time a person could react and say "skip", the server has typically already finished (or
    /// nearly finished) sending the reply's whole audio — closing its context afterward, if it is
    /// still open, is hygiene, not what actually stops the sound.
    public func skip() {
        dependencies.log(
            .info, "tts",
            "skip (\(currentlyPlayingMessageId.map { "interrupted reply \($0)" } ?? "nothing playing"))")
        dependencies.stopPlayback()

        if let interrupted = currentlyPlayingMessageId {
            finalizePlaybackWindow(for: interrupted)
            currentlyPlayingMessageId = nil
            cancelWireReplyIfStillGenerating(interrupted)
        } else if let stillGenerating = queue.head?.messageId {
            // Nothing has started playing yet — the reply being skipped is still purely on the
            // wire. Cancel it there before it ever gets a chance to play.
            cancelWireReplyIfStillGenerating(stillGenerating)
        }

        pumpPlayback()
        refreshStateWhenNothingIsPlaying()
    }

    /// If `messageId` is still the reply actively being generated on the wire, closes its
    /// context — hygiene, per `skip()`'s own comment on why generation is usually already well
    /// ahead of playback by the time this runs — and drops it from the generation queue so
    /// nothing more is ever sent or received for it.
    private func cancelWireReplyIfStillGenerating(_ messageId: Int) {
        guard queue.head?.messageId == messageId else { return }
        let contextIdToClose = currentContextId
        currentContextId = nil
        queue.dropHead()
        resendsForCurrentReply = 0
        Task {
            if let contextIdToClose { await self.sendFrame(.closeContext(contextId: contextIdToClose)) }
            await self.advance()
        }
    }

    /// Ends this session's speech output for the call — closes the socket, drops anything still
    /// queued or buffered unspoken. Nothing here restarts on its own after this; a fresh call
    /// needs a fresh `SpeechOutputSession`.
    public func end() {
        if transport != nil { dependencies.log(.info, "tts", "socket closed (code: 1000)") }
        ended = true
        receiveTask?.cancel()
        keepAliveTask?.cancel()
        dependencies.stopPlayback()
        if let playing = currentlyPlayingMessageId {
            finalizePlaybackWindow(for: playing)
        }
        let transportToClose = transport
        transport = nil
        currentContextId = nil
        keepAliveContextId = nil
        currentlyPlayingMessageId = nil
        buffered = [:]
        readyToPlay = []
        queue = ReplyQueue()
        state = .idle
        Task { await transportToClose?.close(code: 1000, reason: nil) }
    }

    /// The app's player has confirmed every scheduled buffer for `messageId` has actually
    /// finished rendering — called back from `SpeechOutputDependencies.markReplyAudioComplete`'s
    /// own completion handler, never inferred from when audio was merely sent. Finalises that
    /// reply's playback window and starts whichever reply is next in line, if any.
    public func playbackFinished(messageId: Int) {
        guard messageId == currentlyPlayingMessageId else { return }
        dependencies.log(.info, "tts", "reply \(messageId) playback finished")
        finalizePlaybackWindow(for: messageId)
        currentlyPlayingMessageId = nil
        pumpPlayback()
        refreshStateWhenNothingIsPlaying()
    }

    // MARK: - Driving generation

    /// Ensures the wire head is being generated: connects if there is no socket yet, opens a
    /// fresh context if the head has no context open, and (re)sends whatever of its sentences
    /// have not yet been handed to the transport. Runs independently of playback — the whole
    /// point of the split this type is built around.
    private func advance() async {
        guard !ended, let head = queue.head else {
            refreshStateWhenNothingIsPlaying()
            return
        }

        if transport == nil {
            if currentlyPlayingMessageId == nil { state = .connecting }
            do {
                let token = try await dependencies.mintToken(.tts)
                dependencies.log(.info, "tts", "token minted")
                guard let url = VoiceTtsProtocol.connectionURL(voiceId: dependencies.voiceId(), token: token.token)
                else {
                    await handleReplyFailure(reason: "invalid TTS connection URL")
                    return
                }
                let newTransport = dependencies.makeTransport()
                try await newTransport.connect(url: url)
                transport = newTransport
                dependencies.log(.info, "tts", "socket opened")
                startReceiveLoop()
            } catch {
                await handleReplyFailure(reason: "\(error)")
                return
            }
        }

        let contextId = currentContextId ?? UUID().uuidString
        currentContextId = contextId

        let sentencesToSend = head.remaining
        guard !sentencesToSend.isEmpty else {
            // Every sentence was already handed to the transport before a drop; the reply is
            // fully in flight and this call is just waiting on its audio to keep arriving. Only
            // reachable when nothing was dropped: `handleReplyFailure` resets the head's own
            // progress the instant a drop is detected, so `remaining` is never empty for a head
            // whose context just died.
            return
        }

        if recoveringFromDrop {
            dependencies.log(.info, "tts", "replaying reply \(head.messageId) on a fresh context")
        }
        await sendFrame(.initializeContext(contextId: contextId))
        for (index, sentenceText) in sentencesToSend.enumerated() {
            let isLast = index == sentencesToSend.count - 1
            await sendFrame(.sendText(contextId: contextId, text: sentenceText + " ", flush: isLast))
            queue.recordSentencesSent()
        }
        // ElevenLabs sends a context's `isFinal` only once the context is closed — a flush alone
        // generates the audio and then leaves the context open forever, so the reply would never
        // finish playing and nothing queued behind it would ever speak. Closing keeps flushing
        // what is still buffered, and a later close from `skip()` on the same context is harmless.
        await sendFrame(.closeContext(contextId: contextId))
        if recoveringFromDrop {
            recoveringFromDrop = false
            dependencies.log(.info, "tts", "reconnected")
            dependencies.feedback(.ttsReconnected)
        }
    }

    /// A reply could not even be started (mint or connect failed) or the socket dropped while it
    /// was in flight — retried up to `TtsReconnectPolicy.maxResendsPerReply` times on a fresh
    /// context before the reply is abandoned so the queue is not starved by one broken reply.
    /// Audio already heard (or already buffered) for the affected reply is never touched here —
    /// only generation is retried; whatever already played, played.
    private func handleReplyFailure(reason: String) async {
        guard !ended else { return }
        dependencies.log(.warning, "tts", "connection lost: \(reason)")
        transport = nil
        currentContextId = nil
        // The dead socket took every context on it down with it, the idle one included — a fresh
        // connection needs a fresh context, never a ping aimed at one that was never opened on it.
        keepAliveContextId = nil
        // The dead context's own progress means nothing to the fresh one a reconnect opens next
        // — without this, a head whose every sentence had already been handed to that context
        // reports nothing left to send, and neither it nor anything queued behind it ever speaks
        // again.
        queue.resetHeadProgress()
        recoveringFromDrop = true
        dependencies.feedback(.ttsDropped)

        guard !queue.isEmpty else {
            refreshStateWhenNothingIsPlaying()
            return
        }

        resendsForCurrentReply += 1
        guard resendsForCurrentReply <= TtsReconnectPolicy.maxResendsPerReply else {
            let droppedDescription = queue.head.map { "reply \($0.messageId)" } ?? "reply"
            dependencies.log(
                .warning, "tts", "\(droppedDescription) dropped after \(resendsForCurrentReply) failed attempts")
            dependencies.feedback(.replyNotSpoken)
            let abandonedId = queue.dropHead()?.messageId
            resendsForCurrentReply = 0
            if let abandonedId {
                if abandonedId == currentlyPlayingMessageId {
                    // Already playing — nothing more is coming for it, same as an ordinary
                    // finish; whatever was already heard stays heard, the rest is simply absent.
                    dependencies.markReplyAudioComplete(abandonedId)
                } else {
                    // Never got its turn, and never will — nothing salvageable was buffered.
                    buffered.removeValue(forKey: abandonedId)
                }
            }
            await advance()
            return
        }

        if currentlyPlayingMessageId == nil { state = .connecting }
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
            guard let head = queue.head else { return }
            let messageId = head.messageId

            if currentlyPlayingMessageId == nil, readyToPlay.isEmpty {
                // Nothing is playing and nothing is waiting to — this reply becomes the one
                // playing, starting from its very first chunk rather than waiting for its
                // generation to finish and losing the latency multi-context streaming buys.
                currentlyPlayingMessageId = messageId
                playbackStart[messageId] = dependencies.now()
                buffered[messageId] = BufferedReply(text: head.sentences.joined(separator: " "))
                state = .speaking(messageId: messageId)
                dependencies.log(.info, "tts", "reply \(messageId) playback started")
            }

            if messageId == currentlyPlayingMessageId {
                dependencies.playAudio(messageId, samples)
            } else {
                let text = buffered[messageId]?.text ?? head.sentences.joined(separator: " ")
                buffered[messageId, default: BufferedReply(text: text)].chunks.append(samples)
            }

        case .contextFinished(let contextId):
            guard contextId == nil || contextId == currentContextId else { return }
            guard let messageId = queue.head?.messageId else { return }
            queue.completeHead()
            currentContextId = nil
            resendsForCurrentReply = 0

            if messageId == currentlyPlayingMessageId {
                dependencies.markReplyAudioComplete(messageId)
            } else {
                buffered[messageId, default: BufferedReply(text: "")].generationFinished = true
                readyToPlay.append(messageId)
                pumpPlayback()
            }

            Task { await self.advance() }

        case let .serverError(reason, message):
            handleServerRejection(reason: reason, message: message)

        case .unrecognized, nil:
            break
        }
    }

    /// ElevenLabs told us — over the wire, before the close that follows it — that this request
    /// can never succeed. Abandons everything queued or playing immediately (no resend budget
    /// spent chasing a rejection that will not change) and marks the session so every future
    /// reply is skipped without even trying to connect. `end()`'s own teardown is not reused here
    /// since a rejection speaks for the rest of this session, not for closing it — the call keeps
    /// going, replies simply stop being spoken and land in the transcript instead.
    private func handleServerRejection(reason: String, message: String) {
        guard !rejected else { return }
        dependencies.log(.warning, "tts", "server rejected: \(reason)")
        rejected = true
        receiveTask?.cancel()
        let hadQueuedWork = !queue.isEmpty || currentlyPlayingMessageId != nil
        dependencies.stopPlayback()
        if let playing = currentlyPlayingMessageId {
            finalizePlaybackWindow(for: playing)
            currentlyPlayingMessageId = nil
        }
        buffered = [:]
        readyToPlay = []
        queue = ReplyQueue()
        currentContextId = nil
        resendsForCurrentReply = 0
        let transportToClose = transport
        transport = nil
        state = .idle
        dependencies.feedback(.ttsRejected(reason: reason, message: message))
        if hadQueuedWork { dependencies.feedback(.replyNotSpoken) }
        Task { await transportToClose?.close(code: 1000, reason: nil) }
    }

    // MARK: - Playback bookkeeping

    /// Promotes the next reply whose generation has finished into `currentlyPlayingMessageId`,
    /// once nothing is currently playing — draining whatever of its audio arrived while it
    /// waited its turn, and immediately telling the app it has heard the last of that audio if
    /// generation had already finished by the time its turn came (the common case). A reply
    /// whose synthesis produced no audio at all is treated as finished the instant it would have
    /// started, so it can never wedge playback waiting for a signal that will never arrive.
    private func pumpPlayback() {
        guard currentlyPlayingMessageId == nil, !readyToPlay.isEmpty else { return }
        let messageId = readyToPlay.removeFirst()
        let entry = buffered.removeValue(forKey: messageId) ?? BufferedReply(text: "")

        guard !entry.chunks.isEmpty else {
            pumpPlayback()
            return
        }

        currentlyPlayingMessageId = messageId
        playbackStart[messageId] = dependencies.now()
        buffered[messageId] = BufferedReply(text: entry.text)
        state = .speaking(messageId: messageId)
        dependencies.log(.info, "tts", "reply \(messageId) playback started")
        for chunk in entry.chunks { dependencies.playAudio(messageId, chunk) }
        if entry.generationFinished { dependencies.markReplyAudioComplete(messageId) }
    }

    private func finalizePlaybackWindow(for messageId: Int) {
        let text = buffered.removeValue(forKey: messageId)?.text ?? ""
        guard let start = playbackStart.removeValue(forKey: messageId) else { return }
        let end = dependencies.now()
        let window = start <= end ? start...end : start...start
        recentPlayback.append((window: window, text: text))
        let horizon = dependencies.now().addingTimeInterval(-Self.playbackHorizonSeconds)
        recentPlayback.removeAll { $0.window.upperBound < horizon }
    }

    /// Recomputes `state` after playback stops with nothing currently playing — `.connecting`
    /// while generation or buffered-ahead audio is still in flight, `.idle` only once every
    /// pipeline (wire and playback alike) is genuinely empty.
    private func refreshStateWhenNothingIsPlaying() {
        guard currentlyPlayingMessageId == nil else { return }
        state = (queue.head != nil || !buffered.isEmpty || !readyToPlay.isEmpty) ? .connecting : .idle
    }

    private func sendFrame(_ message: TtsUplinkMessage) async {
        guard let transport else { return }
        guard let data = try? message.encoded() else { return }
        try? await transport.send(text: String(decoding: data, as: UTF8.self))
    }
}
