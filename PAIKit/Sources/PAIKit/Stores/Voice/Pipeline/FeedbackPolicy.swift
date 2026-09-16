import Foundation

/// What a ``FeedbackEvent`` should actually cause — a cue, a notification, both or neither.
/// `FeedbackPolicy.decide(_:now:)` is the only place this type is built.
public struct FeedbackAction: Sendable, Equatable {
    /// One notification lifecycle step: a fresh post, or an update of the request already
    /// showing under `key` — the mechanism that turns a flapping connection into one banner with
    /// current numbers instead of a stack of them.
    public struct Notify: Sendable, Equatable {
        public enum Disposition: Sendable, Equatable { case post, update }

        public let disposition: Disposition
        /// Which physical notification this belongs to. Every connection/capture/TTS event
        /// shares `"health"` — the one identifier a take's ride updates in place. Every other
        /// notification gets a key of its own (`fatal:<reason>`, `backfillFailed`, …), matching
        /// "error at most once per cause".
        public let key: String
        /// The event that caused this step — carries whatever wording detail it has
        /// (`serverNotice`'s reason, `fatalProtocolError`'s message); composing the actual title
        /// and body from it is `VoiceFeedbackNotifier`'s job, not this pure value's.
        public let event: FeedbackEvent
        /// How many drop-class events the open health episode has seen so far. The only piece of
        /// wording context this policy can supply on its own — the pending-transcription
        /// duration the design also wants in that notification lives in the transcript ledger,
        /// not here.
        public let episodeDropCount: Int

        public init(disposition: Disposition, key: String, event: FeedbackEvent, episodeDropCount: Int) {
            self.disposition = disposition
            self.key = key
            self.event = event
            self.episodeDropCount = episodeDropCount
        }
    }

    public let cue: EarconKind?
    public let notify: Notify?

    public init(cue: EarconKind? = nil, notify: Notify? = nil) {
        self.cue = cue
        self.notify = notify
    }
}

/// Turns the raw stream of ``FeedbackEvent``s a bad connection can produce — a drop-reconnect
/// cycle every few seconds, for minutes — into "a handful of sounds, not a hundred" and one
/// notification per bad ride instead of thirty.
///
/// A **health episode** covers every connection-, capture- and TTS-socket event that shares the
/// `"health"` notification identifier (the whole table in the design except the standalone error
/// notifications and the command tones): it opens on the first drop-class event, and closes on a
/// `reconnected`/`ttsReconnected` event. **The 10-second-of-stability judgement that decides when
/// a connection is genuinely healthy again is `ConnectionHealth`'s, not this type's** — this
/// policy trusts that `reconnected`/`ttsReconnected` is only handed to it once, when the caller
/// considers the link actually restored, and reacts to it exactly once per open episode. Without
/// that contract there is no way for a value fed one event at a time, with no periodic tick, to
/// tell a flap from a genuine recovery; a caller that instead fires `reconnected` on every bare
/// socket reconnect will see this policy play the `reconnect` cue on every one of them.
///
/// Every decision is `decide(_:now:)` over `self` and the given time — deterministic, so a test
/// drives it with a stepped clock instead of sleeping, and never derives "now" itself.
public struct FeedbackPolicy: Sendable, Equatable {
    /// How rarely a still-open, still-unstable episode may re-notify (never re-cue) while it
    /// drags on — "a tunnel-rich hour gives one banner that keeps its numbers current, not
    /// thirty" applied to the notification body specifically.
    public static let stillUnstableInterval: TimeInterval = 60

    private var healthEpisodeOpen = false
    private var healthDropCount = 0
    private var healthLastNotifiedAt: Date?
    /// Causes that have already fired their one standalone notification this take —
    /// `fatalProtocolError` keyed by its own reason text, everything else by a fixed cause name.
    private var firedCauses: Set<String> = []

    public init() {}

    public mutating func decide(_ event: FeedbackEvent, now: Date) -> FeedbackAction {
        switch event {
        case .connectionDropped, .serverNotice, .mintFailed, .captureRestarted, .ttsDropped:
            return dropClass(event, now: now)
        case .reconnected, .ttsReconnected:
            return reconnectClass(event)
        case .gapOpened:
            return healthUpdate(event, now: now)
        case .backfillCompleted:
            // A healed episode also clears every standing standalone error for this take: a
            // fresh gap that fails again after this is a new problem, worth its own notice.
            firedCauses.removeAll()
            return FeedbackAction(
                cue: .healed,
                notify: .init(disposition: .update, key: "health", event: event, episodeDropCount: healthDropCount))
        case .backfillFailed:
            return causeGated("backfillFailed", event: event)
        case .fatalProtocolError(let reason):
            return causeGated("fatal:\(reason)", event: event)
        case .captureGaveUp:
            return causeGated("captureGaveUp", event: event)
        case .replyNotSpoken:
            // Never deduped: each occurrence names a different reply that was not spoken, not a
            // recurrence of the same standing problem the way a fatal error or a stuck gap is.
            return FeedbackAction(
                cue: .error,
                notify: .init(disposition: .post, key: "replyNotSpoken", event: event, episodeDropCount: 0))
        case .interruptionPaused:
            return FeedbackAction(cue: .pause)
        case .interruptionResumed:
            return FeedbackAction(cue: .reconnect)
        case .commandRecognized(let kind):
            // Confirmations are exempt from every rate limit here — a swallowed one is worse
            // than a chatty one.
            return FeedbackAction(cue: .command(kind))
        case .commandModelMissing(let kind):
            return causeGated("commandModelMissing:\(kind.rawValue)", event: event)
        }
    }

    private mutating func dropClass(_ event: FeedbackEvent, now: Date) -> FeedbackAction {
        let isNewEpisode = !healthEpisodeOpen
        healthEpisodeOpen = true
        healthDropCount += 1
        if isNewEpisode {
            healthLastNotifiedAt = now
            return FeedbackAction(
                cue: .drop,
                notify: .init(disposition: .post, key: "health", event: event, episodeDropCount: healthDropCount))
        }
        // A repeat flap inside the same episode never replays the drop cue, and updates the
        // notification body at most once every `stillUnstableInterval`.
        guard shouldNotifyAgain(now: now) else { return FeedbackAction() }
        healthLastNotifiedAt = now
        return FeedbackAction(
            notify: .init(disposition: .update, key: "health", event: event, episodeDropCount: healthDropCount))
    }

    private mutating func healthUpdate(_ event: FeedbackEvent, now: Date) -> FeedbackAction {
        guard healthEpisodeOpen, shouldNotifyAgain(now: now) else { return FeedbackAction() }
        healthLastNotifiedAt = now
        return FeedbackAction(
            notify: .init(disposition: .update, key: "health", event: event, episodeDropCount: healthDropCount))
    }

    private mutating func reconnectClass(_ event: FeedbackEvent) -> FeedbackAction {
        // A `reconnected` with no episode open is either the take's very first connect (nothing
        // to announce recovering from) or a caller that already closed this episode — either
        // way, silence is correct.
        guard healthEpisodeOpen else { return FeedbackAction() }
        let count = healthDropCount
        healthEpisodeOpen = false
        healthDropCount = 0
        healthLastNotifiedAt = nil
        return FeedbackAction(
            cue: .reconnect,
            notify: .init(disposition: .update, key: "health", event: event, episodeDropCount: count))
    }

    private mutating func causeGated(_ cause: String, event: FeedbackEvent) -> FeedbackAction {
        guard firedCauses.insert(cause).inserted else { return FeedbackAction() }
        return FeedbackAction(
            cue: .error, notify: .init(disposition: .post, key: cause, event: event, episodeDropCount: 0))
    }

    private func shouldNotifyAgain(now: Date) -> Bool {
        guard let healthLastNotifiedAt else { return true }
        return now.timeIntervalSince(healthLastNotifiedAt) >= Self.stillUnstableInterval
    }
}
