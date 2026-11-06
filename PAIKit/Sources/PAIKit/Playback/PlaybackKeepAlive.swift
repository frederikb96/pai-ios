import Foundation

/// Whether autoplay keeps the app running while it is out of sight, so the next reply can start.
///
/// iOS suspends a backgrounded app within seconds of its audio stopping, and a suspended app
/// neither hears its transcript stream nor starts a player; starting audio again from the
/// background is not reliably allowed either. So while autoplay is on and an autoplay session may
/// still answer, the app plays silence underneath the reply and through the gap after it, and
/// lets go once nothing is coming. The app supplies the silence; this decides when.
///
/// Holding begins only where the app still has the right to start audio: while a reply plays, or
/// at the moment the app leaves the screen. A wait the person or the system ended stays ended
/// until a reply plays again or the app is back in front.
public struct PlaybackKeepAlive: Sendable, Equatable {
    /// How long the gap after the last reply, or after the last sign that an autoplay session was
    /// still working, is held before the app may suspend.
    public static let quietGrace: TimeInterval = 120
    /// The longest the app is held with no reply playing, however long a session keeps working.
    public static let maxWait: TimeInterval = 30 * 60

    public struct Inputs: Sendable, Equatable {
        /// The app is not in front of the person (locked, another app, the home screen).
        public var outOfSight: Bool
        /// Some session has playback with autoplay on.
        public var autoplayOn: Bool
        /// The player's state; `nil` when it holds no reply.
        public var player: PlaybackStatus?
        /// A session with autoplay on is mid-turn on a connected stream, so a reply may yet arrive.
        public var autoplayWorking: Bool
        /// A session with autoplay on has a connected stream: a message just sent there may not
        /// show as a turn yet.
        public var autoplayWatching: Bool
        /// A dictation or a call has the audio session; silence must not take it over.
        public var voiceBusy: Bool
        /// Another app is playing; starting silence would cut it off.
        public var otherAppPlaying: Bool

        public init(
            outOfSight: Bool, autoplayOn: Bool, player: PlaybackStatus?, autoplayWorking: Bool,
            autoplayWatching: Bool, voiceBusy: Bool, otherAppPlaying: Bool
        ) {
            self.outOfSight = outOfSight
            self.autoplayOn = autoplayOn
            self.player = player
            self.autoplayWorking = autoplayWorking
            self.autoplayWatching = autoplayWatching
            self.voiceBusy = voiceBusy
            self.otherAppPlaying = otherAppPlaying
        }
    }

    /// Whether silence should be playing now.
    public private(set) var holding = false
    private var outOfSightAt: Date?
    private var lastReplyAt: Date?
    private var lastWorkAt: Date?
    /// The person or the system ended the wait; it stays ended until the app is in front again.
    private var released = false

    public init() {}

    /// Recomputes ``holding`` from what the app shows now. Call it on every change of an input and
    /// periodically while holding, so the grace runs out without anything else happening.
    @discardableResult
    public mutating func update(_ inputs: Inputs, now: Date) -> Bool {
        guard inputs.outOfSight else {
            self = PlaybackKeepAlive()
            return holding
        }
        let leaving = outOfSightAt == nil
        if leaving { outOfSightAt = now }
        let replyInHand = inputs.player == .playing || inputs.player == .loading
        if replyInHand {
            lastReplyAt = now
            // A reply playing again (Play after a call) is audio already running; the wait after
            // it is wanted again.
            released = false
        }
        // Leaving the screen on a watched autoplay session starts the grace: the person may have
        // sent a message and locked the phone before its turn was reported.
        if replyInHand || inputs.autoplayWorking || (leaving && inputs.autoplayWatching) { lastWorkAt = now }
        holding = shouldHold(inputs, replyInHand: replyInHand, leaving: leaving, now: now)
        return holding
    }

    private func shouldHold(_ inputs: Inputs, replyInHand: Bool, leaving: Bool, now: Date) -> Bool {
        if released || !inputs.autoplayOn || inputs.voiceBusy { return false }
        // A reply the person paused, or one that failed, is theirs to resume; nothing to wait for.
        if inputs.player == .paused || inputs.player == .error { return false }
        if replyInHand { return true }
        if !holding {
            // Audio may start out of sight only while some is already playing, or in the moment
            // of leaving the screen; and never over another app's.
            guard leaving, inputs.autoplayWorking || inputs.autoplayWatching, !inputs.otherAppPlaying else {
                return false
            }
        }
        let sinceWork = lastWorkAt.map { now.timeIntervalSince($0) } ?? .infinity
        let sinceReply = now.timeIntervalSince(lastReplyAt ?? outOfSightAt ?? now)
        return sinceWork <= Self.quietGrace && sinceReply <= Self.maxWait
    }

    /// The person paused the wait, or another app or a call took the audio: stop holding until a
    /// reply plays again or the app is in front again.
    public mutating func release() {
        released = true
        holding = false
    }

    /// Whether any session with autoplay on is working on a turn whose stream is connected. A
    /// session not on a live stream keeps its last status forever, so it is not evidence.
    public static func autoplayWorking(
        modes: [String: SessionPlayback], isProcessing: (String) -> Bool, isStreaming: (String) -> Bool
    ) -> Bool {
        modes.contains { id, mode in mode.autoplay && isProcessing(id) && isStreaming(id) }
    }

    /// Whether any session with autoplay on has a connected stream, so an arrival would be heard.
    public static func autoplayWatching(modes: [String: SessionPlayback], isStreaming: (String) -> Bool) -> Bool {
        modes.contains { id, mode in mode.autoplay && isStreaming(id) }
    }
}
