import Foundation

/// Where the engine gets a reply's manifest and segment files; `PaiApiClient` conforms.
public protocol PlaybackSource: Sendable {
    func getPlaybackManifest(sessionId: String, messageId: Int) async throws -> PlaybackManifest
    func fetchPlaybackSegment(sessionId: String, messageId: Int, index: Int) async throws -> PlaybackSegmentAudio
}

extension PaiApiClient: PlaybackSource {}

/// The one audio player behind the engine: one segment file at a time, replaced by the next. The
/// app implements it over `AVAudioPlayer`; tests implement it with a fake. Everything happens on
/// the main actor.
@MainActor
public protocol PlaybackOutput: AnyObject {
    /// Called about twice a second while a segment plays.
    var onTick: (@MainActor () -> Void)? { get set }
    /// The loaded segment played to its end.
    var onFinished: (@MainActor () -> Void)? { get set }
    /// The system paused playback (a call, another app, a headset button, the lock screen).
    var onInterrupted: (@MainActor () -> Void)? { get set }
    /// Position inside the loaded segment, in milliseconds.
    var positionMs: Int { get }
    /// Replaces the loaded segment and positions it; answers its measured length in milliseconds.
    func load(_ data: Data, atMs offsetMs: Int, rate: Double) throws -> Int
    func play() throws
    func pause()
    func seek(toMs offsetMs: Int)
    func setRate(_ rate: Double)
    /// Drops the loaded segment.
    func clear()
}

/// What plays through the output: a reply is a run of segment files fetched one by one (the next
/// one ahead of need) and handed to the output in turn. State for the UI goes to ``PlaybackStore``;
/// this class holds the segments and the intent. Port of the web's `engine.ts`.
@MainActor
public final class PlaybackEngine {
    /// Said in the player's own line when the backup voice starts speaking after another voice.
    public static let backupVoiceNotice = "Backup voice: ElevenLabs is saving credits."
    /// Said once per reply when a part its voice could not read was left out.
    public static let skippedPartNotice = "A part of this reply could not be read aloud and was skipped."
    public static let nothingToReadNotice = "There is nothing to read aloud in this reply."

    /// The reply the engine holds: its manifest and every segment fetched so far.
    private final class Track {
        let sessionId: String
        let messageId: Int
        let title: String
        let manifest: PlaybackManifest
        var index = 0
        var segments: [Int: Data] = [:]
        var inflight: [Int: Task<PlaybackSegmentAudio, Error>] = [:]
        var failed: Set<Int> = []
        /// Parts their voice refused on their own text; asking again would fail the same way.
        var unreadable: Set<Int> = []
        var skipNoted = false
        var measured: [Int: Int] = [:]
        var providers: [Int: PlaybackProvider] = [:]

        init(sessionId: String, messageId: Int, title: String, manifest: PlaybackManifest) {
            self.sessionId = sessionId
            self.messageId = messageId
            self.title = title
            self.manifest = manifest
        }
    }

    private let store: PlaybackStore
    private let source: PlaybackSource
    private let output: PlaybackOutput
    private let notify: @MainActor (_ message: String, _ isWarning: Bool) -> Void

    private var track: Track?
    /// The reply a failed start was for, so Play can try it again.
    private var retry: QueuedReply?
    /// Whether the loaded segment is the one the track points at.
    private var loaded = false
    private var intentToPlay = false
    /// The voice last heard, until the player goes idle.
    private var lastVoice: PlaybackProvider?
    /// Bumped by every start, seek and stop; an answer that finds it moved is stale and dropped.
    private var epoch = 0

    public init(
        store: PlaybackStore, source: PlaybackSource, output: PlaybackOutput,
        notify: @escaping @MainActor (_ message: String, _ isWarning: Bool) -> Void
    ) {
        self.store = store
        self.source = source
        self.output = output
        self.notify = notify
        output.onTick = { [weak self] in self?.tick() }
        output.onFinished = { [weak self] in
            guard let self else { return }
            Task { await self.segmentEnded() }
        }
        output.onInterrupted = { [weak self] in self?.interrupted() }
    }

    // MARK: Starting

    /// Start a reply from its beginning. `user` is a tap: it empties the queue and says out loud
    /// when a reply has nothing to read. Without it this is an autoplay or a queue step, which stays
    /// quiet about a reply that turns out to be all code.
    public func start(sessionId: String, messageId: Int, title: String, user: Bool = false) async {
        if user { store.setQueue([]) }
        epoch += 1
        let mine = epoch
        releaseTrack()
        retry = QueuedReply(sessionId: sessionId, messageId: messageId, title: title)
        intentToPlay = true
        store.setCurrent(PlaybackCurrent(sessionId: sessionId, messageId: messageId, title: title))
        let manifest: PlaybackManifest
        do {
            manifest = try await source.getPlaybackManifest(sessionId: sessionId, messageId: messageId)
        } catch {
            guard mine == epoch else { return }
            if let refusal = error as? PlaybackRefusal, refusal.isNothingToRead {
                if user { notify(Self.nothingToReadNotice, false) }
                retry = nil
                store.setCurrent(nil)
                await startNext()
                return
            }
            fail(error)
            return
        }
        guard mine == epoch else { return }
        let fresh = Track(sessionId: sessionId, messageId: messageId, title: title, manifest: manifest)
        track = fresh
        store.patchCurrent {
            $0.usage = manifest.usage
            $0.durationMs = totalMs()
        }
        await playSegment(0, offsetMs: 0, epoch: mine)
    }

    /// An autoplay arrival: plays now when idle, else waits its turn behind what is playing.
    public func enqueue(_ reply: QueuedReply) async {
        let known =
            store.current?.messageId == reply.messageId || store.queue.contains { $0.messageId == reply.messageId }
        if known { return }
        if store.current == nil {
            await start(sessionId: reply.sessionId, messageId: reply.messageId, title: reply.title)
            return
        }
        store.setQueue(store.queue + [reply])
    }

    // MARK: Transport

    public func play() async {
        guard let current = store.current else { return }
        guard track != nil else {
            if current.status == .error, let retry {
                await start(sessionId: retry.sessionId, messageId: retry.messageId, title: retry.title, user: true)
            }
            return
        }
        intentToPlay = true
        if current.status == .error || !loaded {
            epoch += 1
            await playSegment(track?.index ?? 0, offsetMs: output.positionMs, epoch: epoch)
            return
        }
        store.patchCurrent { $0.notice = nil }
        tryPlay(epoch: epoch)
    }

    public func pause() {
        intentToPlay = false
        output.pause()
        if let current = store.current, current.status != .error {
            store.patchCurrent { $0.status = .paused }
        }
    }

    public func toggle() async {
        guard let status = store.current?.status else { return }
        if status == .playing || (status == .loading && intentToPlay) {
            pause()
        } else {
            await play()
        }
    }

    /// Move within the whole reply, across segment boundaries.
    public func seek(toMs positionMs: Int) async {
        guard let track else { return }
        let durations = PlaybackModel.segmentDurationsMs(track.manifest, measured: track.measured)
        let total = durations.reduce(0, +)
        let (index, offsetMs) = PlaybackModel.locate(
            durationsMs: durations, positionMs: min(max(positionMs, 0), total))
        if index == track.index, loaded {
            output.seek(toMs: offsetMs)
            let position = PlaybackModel.positionOf(durationsMs: durations, index: index, offsetMs: offsetMs)
            store.patchCurrent { $0.positionMs = position }
            return
        }
        epoch += 1
        await playSegment(index, offsetMs: offsetMs, epoch: epoch)
    }

    public func skip(byMs deltaMs: Int) async {
        guard let current = store.current else { return }
        await seek(toMs: current.positionMs + deltaMs)
    }

    /// Let go of the reply and the queue behind it.
    public func stop() {
        epoch += 1
        retry = nil
        intentToPlay = false
        lastVoice = nil
        releaseTrack()
        store.setCurrent(nil)
        store.setQueue([])
    }

    public func setSpeed(_ speed: Double) {
        store.setSpeed(speed)
        output.setRate(speed)
    }

    // MARK: Segments

    private func totalMs() -> Int {
        guard let track else { return 0 }
        return PlaybackModel.segmentDurationsMs(track.manifest, measured: track.measured).reduce(0, +)
    }

    private func playSegment(_ index: Int, offsetMs: Int, epoch mine: Int) async {
        guard let track else { return }
        track.index = index
        loaded = false
        store.patchCurrent {
            $0.status = .loading
            $0.notice = nil
            $0.voiceNote = nil
        }
        let data: Data
        do {
            if track.unreadable.contains(index) { throw PlaybackRefusal.unreadablePart }
            data = try await loadSegment(track, index)
        } catch {
            guard mine == epoch else { return }
            if (error as? PlaybackRefusal)?.isPartFailure == true {
                await skipPart(track, index, epoch: mine)
            } else {
                fail(error)
            }
            return
        }
        guard mine == epoch, self.track === track else { return }
        do {
            let measuredMs = try output.load(data, atMs: offsetMs, rate: store.speed)
            if measuredMs > 0 { track.measured[index] = measuredMs }
        } catch {
            fail(error)
            return
        }
        loaded = true
        let durations = PlaybackModel.segmentDurationsMs(track.manifest, measured: track.measured)
        let position = PlaybackModel.positionOf(durationsMs: durations, index: index, offsetMs: offsetMs)
        store.patchCurrent {
            $0.positionMs = position
            $0.durationMs = durations.reduce(0, +)
        }
        if intentToPlay {
            tryPlay(epoch: mine)
            if mine == epoch, intentToPlay { announceVoice(track.providers[index]) }
        } else {
            store.patchCurrent { $0.status = .paused }
        }
    }

    /// Says once, when the backup voice starts speaking after another voice was heard, that it is
    /// the backup, in the player's own line until the next segment starts. Silent when nothing was
    /// playing before: the first voice heard is not a switch.
    private func announceVoice(_ voice: PlaybackProvider?) {
        guard let voice else { return }
        let before = lastVoice
        lastVoice = voice
        if voice == .openai, let before, before != .openai {
            store.patchCurrent { $0.voiceNote = Self.backupVoiceNotice }
        }
    }

    private func tryPlay(epoch mine: Int) {
        do {
            try output.play()
            guard mine == epoch else { return }
            store.patchCurrent {
                $0.status = .playing
                $0.notice = nil
            }
        } catch {
            guard mine == epoch else { return }
            fail(error)
        }
    }

    private func loadSegment(_ track: Track, _ index: Int) async throws -> Data {
        if let have = track.segments[index] { return have }
        if let pending = track.inflight[index] { return try await pending.value.data }
        track.failed.remove(index)
        let source = self.source
        let sessionId = track.sessionId
        let messageId = track.messageId
        let work = Task {
            try await source.fetchPlaybackSegment(sessionId: sessionId, messageId: messageId, index: index)
        }
        track.inflight[index] = work
        do {
            let audio = try await work.value
            if self.track === track {
                track.segments[index] = audio.data
                if let provider = audio.provider { track.providers[index] = provider }
            }
            track.inflight[index] = nil
            return audio.data
        } catch {
            track.failed.insert(index)
            if (error as? PlaybackRefusal)?.isPartFailure == true { track.unreadable.insert(index) }
            track.inflight[index] = nil
            throw error
        }
    }

    /// Leaves out a part its voice could not read, says so once per reply, and plays on.
    private func skipPart(_ track: Track, _ index: Int, epoch mine: Int) async {
        guard self.track === track else { return }
        if !track.skipNoted {
            track.skipNoted = true
            notify(Self.skippedPartNotice, false)
        }
        if index + 1 < track.manifest.segments.count {
            await playSegment(index + 1, offsetMs: 0, epoch: mine)
        } else {
            await finishReply(track)
        }
    }

    private func fail(_ error: Error) {
        intentToPlay = false
        let message: String
        if let refusal = error as? PlaybackRefusal {
            message = refusal.message
        } else if let paiError = error as? PaiError {
            message = paiError.userMessage
        } else {
            message = "Playback failed."
        }
        output.pause()
        store.patchCurrent {
            $0.status = .error
            $0.notice = message
        }
        notify(message, true)
    }

    private func releaseTrack() {
        track = nil
        loaded = false
        output.clear()
    }

    private func startNext() async {
        guard let next = store.queue.first else { return }
        store.setQueue(Array(store.queue.dropFirst()))
        await start(sessionId: next.sessionId, messageId: next.messageId, title: next.title)
    }

    // MARK: Output events

    private func tick() {
        guard let track, loaded else { return }
        let durations = PlaybackModel.segmentDurationsMs(track.manifest, measured: track.measured)
        let at = output.positionMs
        let position = PlaybackModel.positionOf(durationsMs: durations, index: track.index, offsetMs: at)
        store.patchCurrent { $0.positionMs = position }
        let next = track.index + 1
        if next < durations.count, durations[track.index] - at < PlaybackModel.prefetchAheadMs,
            track.segments[next] == nil, track.inflight[next] == nil, !track.failed.contains(next)
        {
            Task { [weak self] in _ = try? await self?.loadSegment(track, next) }
        }
    }

    private func segmentEnded() async {
        guard let track, loaded else { return }
        let next = track.index + 1
        if next < track.manifest.segments.count {
            await playSegment(next, offsetMs: 0, epoch: epoch)
            return
        }
        await finishReply(track)
    }

    private func finishReply(_ track: Track) async {
        store.markHeard(track.messageId)
        retry = nil
        releaseTrack()
        store.setCurrent(nil)
        await startNext()
        if store.current == nil { lastVoice = nil }
    }

    private func interrupted() {
        guard track != nil, loaded else { return }
        intentToPlay = false
        store.patchCurrent { $0.status = .paused }
    }
}
