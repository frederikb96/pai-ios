import Foundation

/// How serious a ``VoiceLogEntry`` is — mirrors the debug log ring's own levels so a reader
/// familiar with one recognizes the other.
public enum VoiceLogLevel: String, Codable, Sendable, Comparable, CaseIterable {
    case debug, info, warning, error

    private var rank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .warning: 2
        case .error: 3
        }
    }

    public static func < (lhs: VoiceLogLevel, rhs: VoiceLogLevel) -> Bool { lhs.rank < rhs.rank }
}

/// One line of a voice pipeline diagnostics log — a mode transition, a socket lifecycle step, a
/// connection health change, whatever ``VoiceDiagnosticsLog/log(_:_:_:at:)`` was called with.
/// `message` has already been through ``VoiceCredentialRedaction`` by the time this exists.
public struct VoiceLogEntry: Sendable, Equatable {
    public let at: Date
    public let level: VoiceLogLevel
    public let category: String
    public let message: String

    public init(at: Date, level: VoiceLogLevel, category: String, message: String) {
        self.at = at
        self.level = level
        self.category = category
        self.message = message
    }
}

/// The category strings the built-in call sites use — a fixed vocabulary so a reader (or a test)
/// can group lines without guessing at spelling. Not exhaustive: any caller may pass its own
/// string to ``VoiceDiagnosticsLog/log(_:_:_:at:)`` directly when none of these fit.
public enum VoiceLogCategory: String, Sendable {
    /// Take start/stop, call cycles, wake mode ⇄ recording mode.
    case mode
    /// `ConnectionHealth` state transitions.
    case connectionHealth = "connection-health"
    /// Every `FeedbackEvent` — socket drops/reconnects, gaps, backfill, TTS drop/reconnect,
    /// interruptions, command confirmations — whatever `VoiceFeedbackNotifier` turns into a cue or
    /// a notification.
    case feedback
    /// A command the offline engine or the transcript fallback detected, with its score.
    case command
    /// `AVAudioSession` route changes and interruptions.
    case audioSession = "audio-session"
    /// App foreground/background.
    case lifecycle
    /// A draft's clear, flush and reconcile-with-server decisions — not every edit (that would be
    /// once per keystroke, and once every 150ms while a take is live), only the events that decide
    /// whether text a person typed or spoke actually reaches the server and stays there.
    case drafts
}
