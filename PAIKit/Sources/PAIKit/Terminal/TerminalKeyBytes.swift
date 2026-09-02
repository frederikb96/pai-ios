import Foundation

/// The four arrows the terminal action bar offers — the ones a phone has no hardware key for.
public enum TerminalArrowDirection: Equatable, Sendable {
    case up, down, left, right
}

/// The raw VT100 byte sequences the action bar's immediate keys and the field's buffered draft
/// send through `sendTerminalInput`'s raw-bytes route — no backend change needed for any of these.
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
    /// itself. The field buffers its draft locally rather than forwarding it live, so both uses
    /// below send the whole draft in one request, this byte appended:
    ///
    /// The action bar's own Enter/Send appends this with no `literal` flag — `sendTerminalInput`'s
    /// ordinary route already splits on a trailing `\r` and synthesizes a real Enter after typing
    /// the rest, the same as a person typing a line and then pressing Enter. The soft keyboard's
    /// own Return appends the identical byte through the `literal` flag instead, which sends the
    /// whole payload as one unsplit write — the same-chunk arrival is what reads as a line break
    /// rather than a submit.
    public static let submit = "\r"

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
