import Foundation

/// What a stream connection's status display should say. "Connected" alone is not the useful
/// state — Freddy's own bug report was a confidently green "Live" dot over a screen nothing had
/// arrived on in minutes. Whether a quiet stretch is normal or a problem is a question of *time
/// since the last event*, not of whether a socket is open.
public enum StreamActivityState: Equatable, Sendable {
    /// No connection is currently open — matches the existing "Connecting…" label.
    case disconnected
    /// Connected; an event arrived recently, or the connection is still within its opening grace
    /// period and has not had time to be quiet for long yet.
    case receiving
    /// Connected, but nothing has arrived in a while — long enough to be worth a neutral
    /// "quiet" reading without yet claiming something is wrong.
    case idle(secondsSinceLastEvent: TimeInterval)
    /// Connected, but nothing has arrived for long enough that this is worth flagging plainly
    /// rather than reading as a healthy pause.
    case stalled(secondsSinceLastEvent: TimeInterval)
}

/// Pure record of when a stream last connected and last produced an event — kept separate from
/// any client's own reconnect/watchdog state so a view can derive a truthful status display
/// without reaching into connection internals, and so the thresholds are provable without a live
/// clock or a real connection (`now` is always passed in, never read internally).
public struct StreamActivity: Equatable, Sendable {
    private var connectedAt: Date?
    private var lastEventAt: Date?

    public init() {}

    public mutating func recordConnected(at date: Date) {
        connectedAt = date
        lastEventAt = nil
    }

    public mutating func recordDisconnected() {
        connectedAt = nil
        lastEventAt = nil
    }

    /// Called for every event a stream produces that shows the connection is alive — not only
    /// the ones a view has semantic content for. A bare keepalive still counts: it is the
    /// difference between "quiet because nothing has happened" and "quiet because nothing is
    /// getting through", and only the sender can tell those apart.
    public mutating func recordEvent(at date: Date) {
        lastEventAt = date
    }

    /// - Parameters:
    ///   - idleThreshold: elapsed time past which a receiving stream reads as merely quiet.
    ///   - stallThreshold: elapsed time past which a quiet stream reads as worth flagging.
    ///     Independent of any reconnect watchdog's own timeout — this exists to warn a reader
    ///     well before a client gives up and reconnects, not to duplicate that decision.
    public func state(now: Date, idleThreshold: TimeInterval, stallThreshold: TimeInterval) -> StreamActivityState {
        guard let connectedAt else { return .disconnected }
        let elapsed = now.timeIntervalSince(lastEventAt ?? connectedAt)
        if elapsed > stallThreshold { return .stalled(secondsSinceLastEvent: elapsed) }
        if elapsed > idleThreshold { return .idle(secondsSinceLastEvent: elapsed) }
        return .receiving
    }
}
