import Foundation

/// What the offline wake-word engine has actually been doing, summarized into one log line every
/// `interval` seconds. The engine is silent by design — it says nothing until it hears the word —
/// so an engine that has stopped predicting, or whose every prediction is failing, looks exactly
/// like one nobody has spoken to. That is the state this exists to tell apart: with the phone
/// locked in a pocket there is no screen to read, and the device log is the only witness.
public struct WakeWordHeartbeat: Sendable, Equatable {
    /// Long enough that a run of these is readable in a log covering a whole ride, short enough
    /// that the moment the screen locked is still visible in it.
    public static let interval: TimeInterval = 5

    public private(set) var chunks = 0
    public private(set) var rounds = 0
    public private(set) var failures = 0
    public private(set) var maxScore: Float = 0
    private var lastAt: Date?

    public init() {}

    public mutating func chunkIngested() {
        chunks += 1
    }

    public mutating func roundCompleted(score: Float?) {
        rounds += 1
        if let score { maxScore = max(maxScore, score) }
    }

    public mutating func roundFailed() {
        failures += 1
    }

    /// The line to log now, or `nil` while the interval has not elapsed. Reading it clears the
    /// counters, so each line covers only the stretch since the previous one — a running total
    /// would make a stall unreadable.
    public mutating func due(at now: Date) -> String? {
        guard let lastAt else {
            self.lastAt = now
            return nil
        }
        guard now.timeIntervalSince(lastAt) >= Self.interval else { return nil }
        let line =
            "wake word: \(chunks) chunks, \(rounds) rounds, \(failures) failures, "
            + "max score \(String(format: "%.2f", maxScore))"
        self.lastAt = now
        chunks = 0
        rounds = 0
        failures = 0
        maxScore = 0
        return line
    }
}

/// Lets the first occurrence through immediately and at most one per `interval` after that — for
/// a failure that repeats tens of times a second, where every line after the first says the same
/// thing and the file is the only place a device can report from.
public struct LogThrottle: Sendable, Equatable {
    public let interval: TimeInterval
    private var lastAt: Date?

    public init(interval: TimeInterval) {
        self.interval = interval
    }

    public mutating func allows(at now: Date) -> Bool {
        if let lastAt, now.timeIntervalSince(lastAt) < interval { return false }
        lastAt = now
        return true
    }
}
