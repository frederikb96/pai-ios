import Foundation
import Observation

/// What the player is doing with the reply it holds. `loading` is a segment on its way (the first
/// one may be synthesised on that request); `error` carries the sentence to show in `notice`.
public enum PlaybackStatus: Sendable, Equatable {
    case loading, playing, paused, error
}

public struct PlaybackCurrent: Sendable, Equatable {
    public var sessionId: String
    public var messageId: Int
    /// The reply's first words, for the bar and the lock screen.
    public var title: String
    public var status: PlaybackStatus
    /// Whole-reply position and length, in ms; the length is an estimate until every segment is measured.
    public var positionMs: Int
    public var durationMs: Int
    /// A refusal's message or a failure, shown in the bar while `status` is `.error`.
    public var notice: String?
    /// Said once while the part now playing is read by the backup voice; gone at the next segment.
    public var voiceNote: String?
    public var usage: PlaybackUsage?

    public init(
        sessionId: String, messageId: Int, title: String, status: PlaybackStatus = .loading, positionMs: Int = 0,
        durationMs: Int = 0, notice: String? = nil, voiceNote: String? = nil, usage: PlaybackUsage? = nil
    ) {
        self.sessionId = sessionId
        self.messageId = messageId
        self.title = title
        self.status = status
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.notice = notice
        self.voiceNote = voiceNote
        self.usage = usage
    }

    /// The button reads Pause while the voice is going or about to.
    public var isPlayingOrStarting: Bool {
        status == .playing || (status == .loading && positionMs == 0)
    }
}

/// A session's playback switch. Autoplay lives here, never per person: it is what spends credits.
public struct SessionPlayback: Codable, Sendable, Equatable {
    public var autoplay: Bool

    public init(autoplay: Bool = false) {
        self.autoplay = autoplay
    }
}

public struct QueuedReply: Sendable, Equatable {
    public let sessionId: String
    public let messageId: Int
    public let title: String

    public init(sessionId: String, messageId: Int, title: String) {
        self.sessionId = sessionId
        self.messageId = messageId
        self.title = title
    }
}

/// Everything the player UI shows, and the switches that outlive a launch. The engine changes the
/// state; views only read it.
@MainActor
@Observable
public final class PlaybackStore {
    private enum Keys {
        static let modes = "playbackModes"
        static let heard = "playbackHeard"
    }

    static let maxHeard = 500

    /// Sessions with playback on. Persisted, so a relaunch keeps the switch.
    public private(set) var modes: [String: SessionPlayback]
    /// The person's playback speed (`UserSettings.playbackSpeed`), applied by the controller.
    public private(set) var speed: Double = 1
    /// Ids of replies heard to the end, newest last, bounded.
    public private(set) var heard: [Int]
    public private(set) var current: PlaybackCurrent?
    /// Replies waiting behind the current one, in arrival order.
    public private(set) var queue: [QueuedReply] = []
    /// The full-screen view. Not persisted.
    public var sheetOpen = false

    private let storage: SettingsKeyValueStore

    public init(storage: SettingsKeyValueStore) {
        self.storage = storage
        modes = storage.value(forKey: Keys.modes) ?? [:]
        heard = storage.value(forKey: Keys.heard) ?? []
    }

    public func isOn(_ sessionId: String) -> Bool { modes[sessionId] != nil }

    public func enable(_ sessionId: String) {
        guard modes[sessionId] == nil else { return }
        modes[sessionId] = SessionPlayback()
        storage.setValue(modes, forKey: Keys.modes)
    }

    public func disable(_ sessionId: String) {
        modes[sessionId] = nil
        queue.removeAll { $0.sessionId == sessionId }
        storage.setValue(modes, forKey: Keys.modes)
    }

    public func setAutoplay(_ sessionId: String, _ autoplay: Bool) {
        guard modes[sessionId] != nil else { return }
        modes[sessionId] = SessionPlayback(autoplay: autoplay)
        storage.setValue(modes, forKey: Keys.modes)
    }

    public func setSpeed(_ speed: Double) {
        self.speed = speed
    }

    public func markHeard(_ messageId: Int) {
        heard = Array((heard.filter { $0 != messageId } + [messageId]).suffix(Self.maxHeard))
        storage.setValue(heard, forKey: Keys.heard)
    }

    public func setCurrent(_ current: PlaybackCurrent?) {
        self.current = current
    }

    public func patchCurrent(_ change: (inout PlaybackCurrent) -> Void) {
        guard var next = current else { return }
        change(&next)
        current = next
    }

    public func setQueue(_ queue: [QueuedReply]) {
        self.queue = queue
    }
}
