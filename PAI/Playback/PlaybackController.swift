import Foundation
import MediaPlayer
import Observation
import PAIKit

/// The app's one player, global like the call controller: a reply keeps playing across screens,
/// with the screen locked, and from the lock screen and the headset.
///
/// A transcript cell is its own SwiftUI tree and cannot read the screen's environment, so the Listen
/// chips reach this through ``shared``. Everything that decides what plays is the package's
/// ``PlaybackEngine``; this class wires it to the speaker (``AudioPlayerOutput``), the Now Playing
/// card and remote commands, the person's speed, autoplay arrivals and the dictation that pauses a
/// reply.
@MainActor
@Observable
final class PlaybackController {
    static let shared = PlaybackController()

    let store: PlaybackStore
    @ObservationIgnored private let output = AudioPlayerOutput()
    @ObservationIgnored private var engine: PlaybackEngine?
    @ObservationIgnored private var transcript: TranscriptStore?
    @ObservationIgnored private var sessions: SessionListStore?
    @ObservationIgnored private var toasts: ToastCenter?
    @ObservationIgnored private var userSettings: UserSettingsStore?
    @ObservationIgnored private var voice: VoiceRecorderController?
    @ObservationIgnored private var watcher = PlaybackReplyWatcher()
    /// Bumped by every `configure`/`reset`, so the observation loops of an earlier connection end.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var commandsRegistered = false
    @ObservationIgnored private var shownMessage: Int?
    @ObservationIgnored private var lastInfoAt = Date.distantPast

    @ObservationIgnored var fixtureApplied = false

    private init() {
        #if DEBUG
            if PaiFixtureLaunch.isEnabled() {
                store = PlaybackStore(storage: EphemeralSettingsStore())
                return
            }
        #endif
        store = PlaybackStore(storage: UserDefaults.standard)
    }

    // MARK: Connection

    func configure(
        api: PaiApiClient, transcript: TranscriptStore, sessions: SessionListStore, toasts: ToastCenter,
        userSettings: UserSettingsStore, voice: VoiceRecorderController
    ) {
        generation += 1
        let mine = generation
        self.transcript = transcript
        self.sessions = sessions
        self.toasts = toasts
        self.userSettings = userSettings
        self.voice = voice
        watcher = PlaybackReplyWatcher()
        engine = PlaybackEngine(store: store, source: api, output: output) { [weak toasts] message, warning in
            toasts?.show(message, kind: warning ? .error : .info)
        }
        registerRemoteCommands()
        track(mine, { userSettings.settings?.playbackSpeed }) { [weak self] in self?.applySpeed() }
        applySpeed()
        track(mine, { [store] in store.modes }) { [weak self] in self?.watchArrivals() }
        track(mine, { transcript.messages }) { [weak self] in self?.watchArrivals() }
        track(mine, { transcript.windows }) { [weak self] in self?.watchArrivals() }
        watchArrivals()
        track(mine, { voice.state }) { [weak self] in self?.dictationMayHaveStarted() }
        track(mine, { [store] in store.current }) { [weak self] in self?.updateNowPlaying() }
    }

    /// Lets go of the player when the person signs out.
    func reset() {
        generation += 1
        engine?.stop()
        engine = nil
        transcript = nil
        sessions = nil
        toasts = nil
        userSettings = nil
        voice = nil
        updateNowPlaying()
    }

    /// Runs `apply` each time what `read` observes changes, until the connection that asked is gone.
    private func track<T>(_ mine: Int, _ read: @escaping @MainActor () -> T, _ apply: @escaping @MainActor () -> Void) {
        withObservationTracking {
            _ = read()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == mine else { return }
                apply()
                self.track(mine, read, apply)
            }
        }
    }

    // MARK: What the buttons do

    /// A tap on a reply's Listen chip: start it, or pause/resume it when it is the one in hand.
    func playReply(sessionId: String, messageId: Int, title: String) {
        guard let engine else { return }
        if !store.isOn(sessionId) {
            store.enable(sessionId)
            toasts?.show("Playback is on for this session. Turn it off in the plus menu; autoplay is in the player.")
        }
        if let current = store.current, current.messageId == messageId, current.status != .error {
            Task { await engine.toggle() }
            return
        }
        Task { await engine.start(sessionId: sessionId, messageId: messageId, title: title, user: true) }
    }

    /// The plus menu's switch.
    func setSessionPlayback(_ sessionId: String, on: Bool) {
        if on {
            store.enable(sessionId)
            return
        }
        store.disable(sessionId)
        if store.current?.sessionId == sessionId { engine?.stop() }
    }

    func toggle() {
        guard let engine else { return }
        Task { await engine.toggle() }
    }

    func skip(byMs delta: Int) {
        guard let engine else { return }
        Task { await engine.skip(byMs: delta) }
    }

    func seek(toMs position: Int) {
        guard let engine else { return }
        Task { await engine.seek(toMs: position) }
    }

    func pause() {
        engine?.pause()
    }

    /// The reply before (`-1`) or after (`1`) the current one in its session; nothing at an end.
    func stepReply(_ direction: Int) {
        guard let engine, let current = store.current else { return }
        let replies = playableReplies(in: current.sessionId)
        guard let at = replies.firstIndex(where: { $0.id == current.messageId }) else { return }
        let target = at + direction
        guard replies.indices.contains(target) else { return }
        let reply = replies[target]
        Task {
            await engine.start(
                sessionId: current.sessionId, messageId: reply.id, title: PlaybackModel.snippet(of: reply), user: true)
        }
    }

    /// The person's speed: shown at once, saved to their settings.
    func setSpeed(_ speed: Double) {
        engine?.setSpeed(speed)
        guard let userSettings else { return }
        Task { await userSettings.update(UserSettingsPatch(playbackSpeed: speed)) }
    }

    func playableReplies(in sessionId: String) -> [Message] {
        (transcript?.messages[sessionId] ?? []).filter(PlaybackModel.isPlayable)
    }

    func sessionTitle(_ sessionId: String) -> String {
        sessions?.session(withId: sessionId).map(SessionListDomain.sessionHeaderTitle(for:)) ?? "PAI"
    }

    // MARK: Following the app

    private func applySpeed() {
        let speed = userSettings?.settings?.playbackSpeed ?? 1
        guard speed != store.speed else { return }
        engine?.setSpeed(speed)
    }

    private func watchArrivals() {
        guard let transcript, let engine else { return }
        let arrived = watcher.arrivals(modes: store.modes, messages: transcript.messages, windows: transcript.windows)
        for message in arrived {
            let reply = QueuedReply(
                sessionId: message.sessionId, messageId: message.id, title: PlaybackModel.snippet(of: message))
            Task { await engine.enqueue(reply) }
        }
    }

    /// A dictation that starts pauses a playing reply: the speaker's voice would reach the
    /// microphone. Pressing Play while recording plays anyway; nothing blocks either.
    private func dictationMayHaveStarted() {
        guard let voice, voice.state != .idle, store.current?.status == .playing else { return }
        engine?.pause()
    }

    // MARK: Lock screen and headset

    private func registerRemoteCommands() {
        guard !commandsRegistered else { return }
        commandsRegistered = true
        let center = MPRemoteCommandCenter.shared()
        let skip = NSNumber(value: Double(PlaybackModel.skipMs) / 1000)
        center.skipForwardCommand.preferredIntervals = [skip]
        center.skipBackwardCommand.preferredIntervals = [skip]
        // The system calls these on a queue of its own: the closure is `@Sendable`, so it is not
        // main-actor isolated, and it takes only values out of the event before hopping.
        func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor (_ position: Double?) -> Void) {
            command.isEnabled = true
            command.addTarget { @Sendable event in
                let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
                Task { @MainActor in action(position) }
                return .success
            }
        }
        handle(center.playCommand) { [weak self] _ in
            guard let self, self.store.current?.status != .playing else { return }
            self.toggle()
        }
        handle(center.pauseCommand) { [weak self] _ in self?.pause() }
        handle(center.togglePlayPauseCommand) { [weak self] _ in self?.toggle() }
        handle(center.skipForwardCommand) { [weak self] _ in self?.skip(byMs: PlaybackModel.skipMs) }
        handle(center.skipBackwardCommand) { [weak self] _ in self?.skip(byMs: -PlaybackModel.skipMs) }
        handle(center.nextTrackCommand) { [weak self] _ in self?.stepReply(1) }
        handle(center.previousTrackCommand) { [weak self] _ in self?.stepReply(-1) }
        handle(center.changePlaybackPositionCommand) { [weak self] position in
            guard let position else { return }
            self?.seek(toMs: Int((position * 1000).rounded()))
        }
    }

    /// Mirrors the player onto the lock screen's card. The position moves on its own between
    /// updates (the card extrapolates from the rate), so it is rewritten when something changed that
    /// it could not guess: another reply, play/pause, a seek, a new length.
    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let current = store.current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            shownMessage = nil
            return
        }
        let playing = current.status == .playing
        center.playbackState = playing ? .playing : .paused
        let rate = playing ? store.speed : 0
        let info = center.nowPlayingInfo
        let shownElapsed = info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0
        let expectedElapsed =
            shownElapsed + Date().timeIntervalSince(lastInfoAt)
            * (info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0)
        let jumped = abs(expectedElapsed - Double(current.positionMs) / 1000) > 1.5
        let changed =
            shownMessage != current.messageId || info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double != rate
            || jumped || Date().timeIntervalSince(lastInfoAt) > 30
        guard changed else { return }
        shownMessage = current.messageId
        lastInfoAt = Date()
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: "PAI",
            MPMediaItemPropertyAlbumTitle: sessionTitle(current.sessionId),
            MPMediaItemPropertyPlaybackDuration: Double(current.durationMs) / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(current.positionMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
        ]
    }
}

#if DEBUG
    import SwiftUI

    /// Fixture mode keeps nothing on the simulator between launches: a switch left over from one
    /// screenshot would put a bar on the next.
    final class EphemeralSettingsStore: SettingsKeyValueStore, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: Data] = [:]

        func data(forKey key: String) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return items[key]
        }

        func setData(_ value: Data?, forKey key: String) {
            lock.lock()
            items[key] = value
            lock.unlock()
        }
    }

    extension PlaybackController {
        /// `-PaiFixturePlayback`: puts the player in a state a screenshot can show, on the session the
        /// fixture opens. Runs once, when that session's composer first appears.
        func applyFixtureLaunch(sessionId: String) async {
            guard PaiFixtureLaunch.isEnabled(), let state = PaiFixtureLaunch.requestedPlayback(),
                !fixtureApplied, let engine
            else { return }
            fixtureApplied = true
            store.enable(sessionId)
            guard state != "on" else { return }
            await engine.start(
                sessionId: sessionId, messageId: PaiFixtures.playbackReplyId, title: "Both halves are done.",
                user: true)
            engine.pause()
            if state == "sheet" { store.sheetOpen = true }
        }
    }
#endif
