import Foundation

/// A run of text sharing one style — the unit a view draws.
public struct TerminalRun: Equatable, Sendable {
    public let text: String
    public let style: TerminalStyle

    public init(text: String, style: TerminalStyle) {
        self.text = text
        self.style = style
    }
}

/// One row of the pane, left exactly as captured — trailing padding included. The pane is a fixed
/// 200 columns (``TerminalPaneGeometry/columns``) that no phone screen fits, so horizontal scroll
/// is the view's answer, and that needs every column's real content, not a trimmed line.
public struct TerminalLine: Equatable, Sendable {
    public let runs: [TerminalRun]

    public init(runs: [TerminalRun]) {
        self.runs = runs
    }
}

/// A fully parsed screen — what one ``TerminalAnsiParser/parse(_:)`` call produces from the
/// folded pane text.
public struct TerminalScreen: Equatable, Sendable {
    public let lines: [TerminalLine]

    public init(lines: [TerminalLine]) {
        self.lines = lines
    }

    /// The state before any frame has ever arrived — distinct from parsing an actually-received
    /// empty snapshot, which is one blank line rather than zero.
    public static let empty = TerminalScreen(lines: [])
}

/// `agent/src/tmux.ts`'s `PANE_COLS`/`PANE_ROWS` — fixed, with no resize endpoint. Kept here so a
/// view computing horizontal-scroll width doesn't re-derive the magic numbers.
public enum TerminalPaneGeometry {
    public static let columns = 200
    public static let rows = 50
}

/// The terminal pane's whole state, as a view needs it. ``applying(_:)`` is the only way to
/// advance it, so the raw buffer and its parsed screen can never drift apart from each other.
public struct TerminalPaneState: Equatable, Sendable {
    public let rawText: String
    public let screen: TerminalScreen
    public let live: Bool

    public static let initial = TerminalPaneState(rawText: "", screen: .empty, live: true)

    private init(rawText: String, screen: TerminalScreen, live: Bool) {
        self.rawText = rawText
        self.screen = screen
        self.live = live
    }

    public func applying(_ chunk: TerminalFrameChunk) -> TerminalPaneState {
        let folded = TerminalFrameFolder.fold(previous: rawText, chunk: chunk.data)
        return TerminalPaneState(rawText: folded, screen: TerminalAnsiParser.parse(folded), live: chunk.live)
    }
}
