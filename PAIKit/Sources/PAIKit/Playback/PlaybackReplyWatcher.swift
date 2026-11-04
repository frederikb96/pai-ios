import Foundation

/// Notices replies that arrive in a session with playback on. A session's first sight after the
/// switch (or a relaunch) only records where its transcript ends, so history that loads is never
/// read out; only rows past that point count as arrivals. A window that is not at the live edge (a
/// jump into history) catches up silently too. Mirrors the web's `replyWatcher.ts`.
public struct PlaybackReplyWatcher: Sendable {
    private var seenUpTo: [String: Int] = [:]

    public init() {}

    /// The replies that arrived since the last call, to hand to the engine.
    public mutating func arrivals(
        modes: [String: SessionPlayback], messages: [String: [Message]], windows: [String: TranscriptWindow]
    ) -> [Message] {
        for sessionId in seenUpTo.keys where modes[sessionId] == nil { seenUpTo[sessionId] = nil }
        var arrived: [Message] = []
        for (sessionId, mode) in modes.sorted(by: { $0.key < $1.key }) {
            guard let window = windows[sessionId], window.bootstrapped else { continue }
            let rows = messages[sessionId] ?? []
            let newest = rows.last?.id ?? 0
            let before = seenUpTo[sessionId]
            seenUpTo[sessionId] = max(before ?? 0, newest)
            guard let before, newest > before else { continue }
            if !mode.autoplay || window.hasNewer { continue }
            arrived += rows.filter { $0.id > before && PlaybackModel.isPlayable($0) }
        }
        return arrived
    }
}
