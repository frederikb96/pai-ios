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

    /// The Enter byte, `\r` — used two ways, and it is the same byte both times. A synthesized
    /// Enter keypress and a literal carriage return deliver an identical byte to the program on
    /// the other end; what tells the pane's prompt "submit" from "insert a line break" is purely
    /// whether this arrives in its own read or alongside other input, not anything about the byte
    /// itself. The action bar's own Enter/Send sends this alone, with no flag, and submits.
    ///
    /// The soft keyboard's own Return sends the identical byte through `sendTerminalInput`'s
    /// `literal` flag instead, right after whatever character was just typed — this field forwards
    /// every keystroke the moment it happens, so by the time Return fires there is nothing left to
    /// bundle it with in one call; it relies on landing close enough behind the character that
    /// preceded it to read as the same input rather than a bare Enter arriving alone. 🚨 That
    /// reliance is unverified against a live pane at the time this shipped.
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
}
