import Foundation

/// When a stream that looks open should be replaced at once instead of waiting for its stale
/// watchdog. A phone that was asleep or in the background leaves a connection nothing reads and
/// nothing reports as broken; the watchdog notices only after its own timeout, so a transcript
/// can sit frozen for the better part of a minute after the app is back in front of the reader.
/// Coming to the foreground and regaining the network are the earliest evidence the connection
/// may be dead, so the streams check themselves on them.
public enum StreamRevival {
    /// How long a stream may stay silent before a wake stops trusting it. The server pings every
    /// 15 seconds, so a live connection is never older than this.
    public static let idleThreshold: TimeInterval = 20

    /// Whether a wake should replace the connection. A stopped or finished stream stays that
    /// way; `force` skips the silence check, for a network that has just come back and may have
    /// changed under a connection that was heard from a moment ago.
    public static func shouldReconnect(
        stopped: Bool, terminal: Bool, sinceLastEvent: TimeInterval, force: Bool
    ) -> Bool {
        if stopped || terminal { return false }
        return force || sinceLastEvent > idleThreshold
    }
}

/// The app-wide "look at your connections again" signal. Whoever learns that the app is back in
/// front of the reader or that the network returned posts it; each stream owner listens and asks
/// its own client to revive, so no owner needs to know about the others.
public enum StreamWake {
    public static let name = Notification.Name("PAIStreamWake")
    private static let forceKey = "force"

    /// `force` is for a network that returned; a plain foreground only replaces a connection
    /// that went quiet.
    public static func post(force: Bool, center: NotificationCenter = .default) {
        center.post(name: name, object: nil, userInfo: [forceKey: force])
    }

    public static func isForced(_ notification: Notification) -> Bool {
        notification.userInfo?[forceKey] as? Bool ?? false
    }
}
