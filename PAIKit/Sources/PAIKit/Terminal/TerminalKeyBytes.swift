import Foundation

/// The four arrows the terminal action bar offers — the ones a phone has no hardware key for.
public enum TerminalArrowDirection: Equatable, Sendable {
    case up, down, left, right
}

/// The raw VT100 byte sequences the action bar and the terminal's own keystroke forwarding send
/// through `sendTerminalInput`'s raw-bytes route — no backend change needed for any of these.
public enum TerminalKeyBytes {
    public static func arrow(_ direction: TerminalArrowDirection) -> String {
        switch direction {
        case .up: return "\u{1b}[A"
        case .down: return "\u{1b}[B"
        case .right: return "\u{1b}[C"
        case .left: return "\u{1b}[D"
        }
    }

    public static let escape = "\u{1b}"

    /// A real submitting Enter — a bare `\r` already submits today, on both clients, through the
    /// existing route; nothing here needs a leading escape or any other decoration.
    public static let submit = "\r"

    /// One backspace/delete keystroke, sent once per character removed from the local field so a
    /// selection-delete or a fast multi-character backspace reaches the pane as the same number
    /// of keystrokes a person typing them one at a time would have sent.
    public static let delete = "\u{7f}"

    /// A control chord for a single letter — `nil` for anything that is not an ASCII letter, since
    /// the classic `letter - 64` chord table only ever covers A–Z. Case-insensitive: Control-B and
    /// Control-b are the same chord on every terminal, `chr(2)`.
    public static func controlChord(for letter: Character) -> String? {
        guard let scalar = letter.uppercased().unicodeScalars.first,
            (65...90).contains(scalar.value)
        else { return nil }
        guard let chord = Unicode.Scalar(scalar.value - 64) else { return nil }
        return String(Character(chord))
    }

    /// A line break inside the pane's own prompt, without submitting — what the soft keyboard's
    /// Return key sends, as opposed to ``submit``.
    ///
    /// Not a bare `\n`: `agent/src/tmux.ts`'s `type()` splits on every `\r`/`\n` it sees, from
    /// either client, and turns each one into a separately synthesized `tmux send-keys Enter` —
    /// a submit, not a literal newline — regardless of what surrounds it in the payload. A literal
    /// backslash immediately before the break is Claude Code's own documented multi-line-input
    /// shortcut, and reaches `tmux.type()` as the identical byte pattern a person typing `\<Enter>`
    /// would produce.
    ///
    /// 🚨 Unverified against a live pane at the time this shipped — this exact byte sequence
    /// still needs a live test against a real session before it can be trusted. Kept as one
    /// named constant rather than inlined at each call site, so confirming or correcting it is
    /// a one-line change.
    public static let paneNewline = "\\\n"
}
