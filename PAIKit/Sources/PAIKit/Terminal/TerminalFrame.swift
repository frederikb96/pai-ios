import Foundation

/// One decoded terminal-stream event: a chunk of raw pane text plus the `live` flag
/// (docs/ARCHITECTURE.md "Terminal streaming"; mirrors `terminalStream.ts`'s
/// `TerminalStreamCallbacks.onFrame`). Defined here rather than reused from the streaming client
/// so this module has no dependency on it — whatever holds both wires them together.
public struct TerminalFrameChunk: Equatable, Sendable {
    public let data: String
    public let live: Bool

    public init(data: String, live: Bool) {
        self.data = data
        self.live = live
    }
}

/// Folds the terminal stream's frame chunks into the current full-screen snapshot.
///
/// The agent prepends `resetSequence` to every capture (`agent/src/terminal.ts`'s
/// `RESET_SCREEN`) and always sends the whole pane, never a diff — so a chunk containing it
/// replaces the buffer outright, and a chunk without one is a continuation of an already-started
/// snapshot. In ordinary operation every chunk carries the marker (the agent never emits a
/// partial frame), so the continuation branch exists only for a fallback path upstream that could
/// hand this a raw, non-JSON chunk instead of a decoded one.
public enum TerminalFrameFolder {

    /// Cursor-home + erase-screen. Matches `agent/src/terminal.ts`'s `RESET_SCREEN` exactly —
    /// widening or narrowing it here would make this client disagree with the agent about where
    /// a frame begins.
    public static let resetSequence = "\u{1B}[H\u{1B}[2J"

    /// The *last* occurrence wins, not the first: the marker could in principle also appear
    /// inside the captured pane content (a nested shell clearing its own screen), and only the
    /// final one marks where the snapshot this chunk actually carries begins.
    public static func fold(previous: String, chunk: String) -> String {
        if let range = chunk.range(of: resetSequence, options: .backwards) {
            return String(chunk[range.upperBound...])
        }
        return previous + chunk
    }
}
