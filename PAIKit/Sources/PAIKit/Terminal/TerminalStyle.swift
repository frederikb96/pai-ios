import Foundation

/// A terminal color as SGR expresses it — never resolved to a concrete RGB here, since the
/// 16-slot palette is a theme choice the view makes (light/dark mirror what `TerminalView.tsx`
/// hardcodes for xterm), not something this layer can decide.
public enum TerminalColor: Equatable, Sendable {
    /// SGR 30-37 / 90-97 (foreground) and 40-47 / 100-107 (background), collapsed to one 0-15
    /// palette index — 0-7 the normal slot, 8-15 its bright variant.
    case standard(UInt8)
    /// SGR `38;5;n` / `48;5;n` — the 256-color palette.
    case indexed(UInt8)
    /// SGR `38;2;r;g;b` / `48;2;r;g;b` — 24-bit truecolor.
    case trueColor(UInt8, UInt8, UInt8)
}

/// The SGR attributes active at a point in the stream. Carries across a line break — tmux's
/// capture only re-emits an SGR code where an attribute actually changes, not at the start of
/// every row.
public struct TerminalStyle: Equatable, Sendable {
    public var foreground: TerminalColor?
    public var background: TerminalColor?
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false

    public init(
        foreground: TerminalColor? = nil,
        background: TerminalColor? = nil,
        bold: Bool = false,
        dim: Bool = false,
        italic: Bool = false,
        underline: Bool = false
    ) {
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
    }
}
