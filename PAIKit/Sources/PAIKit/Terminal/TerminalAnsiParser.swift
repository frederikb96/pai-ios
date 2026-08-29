import Foundation

/// Turns one folded pane snapshot (already stripped of the frame's own reset marker by
/// ``TerminalFrameFolder``) into a ``TerminalScreen``.
///
/// `tmux capture-pane -e` resolves the grid to its final visual state before emitting anything —
/// there is no cursor addressing left to replay — but it can still emit non-color CSI (cursor
/// positioning it did not collapse away, erase-in-line) and, from whatever ran inside the pane,
/// OSC sequences such as a hyperlink. Both are recognised and dropped rather than rendered as
/// text. Anything that looks like an escape sequence but never completes — cut off at the end of
/// the snapshot — is kept as literal text instead: losing characters is worse than losing a
/// color, and a sequence a real terminal would also fail to finish is not one this parser should
/// guess the shape of.
public enum TerminalAnsiParser {

    public static func parse(_ text: String) -> TerminalScreen {
        var lines: [TerminalLine] = []
        var runs: [TerminalRun] = []
        var buffer = ""
        var style = TerminalStyle()

        func flushRun() {
            guard !buffer.isEmpty else { return }
            runs.append(TerminalRun(text: buffer, style: style))
            buffer = ""
        }
        func flushLine() {
            flushRun()
            lines.append(TerminalLine(runs: runs))
            runs = []
        }

        var rest = Substring(text)
        while let char = rest.first {
            switch char {
            case "\n":
                flushLine()
                rest = rest.dropFirst()

            case "\r":
                // The pane uses bare `\n` between rows (the web enables xterm's `convertEol` to
                // compensate) — a `\r` here carries no cursor-addressing meaning this layer
                // honours, so it is dropped rather than drawn.
                rest = rest.dropFirst()

            case "\u{1B}":
                let afterEsc = rest.dropFirst()
                switch afterEsc.first {
                case "[":
                    if let sequence = parseCSI(afterEsc.dropFirst()) {
                        if sequence.finalByte == "m" {
                            let newStyle = applyingSGR(sequence.params, to: style)
                            if newStyle != style {
                                flushRun()
                                style = newStyle
                            }
                        }
                        // Any other final byte is a recognised CSI that is not color — dropped
                        // silently rather than left on screen as literal characters.
                        rest = sequence.remainder
                    } else {
                        // Truncated at the end of the snapshot — keep the ESC as text rather
                        // than guessing where the sequence would have ended.
                        buffer.append(char)
                        rest = afterEsc
                    }

                case "]":
                    if let remainder = consumeOSC(afterEsc.dropFirst()) {
                        rest = remainder
                    } else {
                        buffer.append(char)
                        rest = afterEsc
                    }

                default:
                    // A lone ESC, or an intro this parser does not recognise: keep it as text
                    // rather than swallowing whatever character follows it.
                    buffer.append(char)
                    rest = afterEsc
                }

            default:
                buffer.append(char)
                rest = rest.dropFirst()
            }
        }
        flushLine()

        return TerminalScreen(lines: lines)
    }

    // MARK: - CSI

    private struct CSISequence {
        let finalByte: Character
        let params: [Int]
        let remainder: Substring
    }

    /// `rest` starts right after `ESC [`. ECMA-48's CSI shape: parameter bytes (0x30-0x3F), then
    /// intermediate bytes (0x20-0x2F), then exactly one final byte (0x40-0x7E). Returns nil when
    /// no final byte is reached before the snapshot ends — the caller treats that as truncated,
    /// not as "no sequence here".
    private static func parseCSI(_ rest: Substring) -> CSISequence? {
        var cursor = rest.startIndex
        while cursor < rest.endIndex, let byte = rest[cursor].asciiValue, (0x30...0x3F).contains(byte) {
            cursor = rest.index(after: cursor)
        }
        let paramsEnd = cursor
        while cursor < rest.endIndex, let byte = rest[cursor].asciiValue, (0x20...0x2F).contains(byte) {
            cursor = rest.index(after: cursor)
        }
        guard cursor < rest.endIndex, let byte = rest[cursor].asciiValue, (0x40...0x7E).contains(byte) else {
            return nil
        }

        // A private-mode marker (`?`, `<`, `=`, `>`) or a `:` sub-parameter separator can land in
        // a parameter group alongside digits; stripped rather than rejected, so a code this
        // parser doesn't special-case still yields a number instead of failing the whole sequence.
        let params = rest[rest.startIndex..<paramsEnd]
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { group -> Int in
                let digits = String(group).filter { $0.isASCII && $0.isNumber }
                return Int(digits) ?? 0
            }

        return CSISequence(finalByte: rest[cursor], params: params, remainder: rest[rest.index(after: cursor)...])
    }

    /// SGR parameters, applied in order onto a copy of `style`. Unrecognised codes (there are
    /// many — underline styles, blink, strikethrough, font selection) are skipped without
    /// disturbing whatever came before or after them.
    private static func applyingSGR(_ params: [Int], to style: TerminalStyle) -> TerminalStyle {
        var style = style
        var index = params.startIndex
        while index < params.endIndex {
            switch params[index] {
            case 0: style = TerminalStyle()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 30...37: style.foreground = .standard(UInt8(params[index] - 30))
            case 39: style.foreground = nil
            case 40...47: style.background = .standard(UInt8(params[index] - 40))
            case 49: style.background = nil
            case 90...97: style.foreground = .standard(UInt8(params[index] - 90 + 8))
            case 100...107: style.background = .standard(UInt8(params[index] - 100 + 8))
            case 38, 48:
                let isForeground = params[index] == 38
                let extended = consumeExtendedColor(params, from: index)
                if let color = extended.color {
                    if isForeground { style.foreground = color } else { style.background = color }
                }
                index = extended.nextIndex
                continue
            default:
                break  // unrecognised SGR code: state unchanged, nothing lost
            }
            index += 1
        }
        return style
    }

    /// `params[from]` is the `38`/`48` code itself. Reads the `5;n` (indexed) or `2;r;g;b`
    /// (truecolor) form that follows and reports how far it consumed. A form cut short by the end
    /// of the parameter list consumes only the mode selector, so parsing resumes at whatever
    /// comes next instead of misreading it as color components.
    private static func consumeExtendedColor(
        _ params: [Int], from index: Int
    ) -> (color: TerminalColor?, nextIndex: Int) {
        guard index + 1 < params.count else { return (nil, index + 1) }
        switch params[index + 1] {
        case 5 where index + 2 < params.count:
            return (.indexed(UInt8(clamping: params[index + 2])), index + 3)
        case 2 where index + 4 < params.count:
            let components = (index + 2...index + 4).map { UInt8(clamping: params[$0]) }
            return (.trueColor(components[0], components[1], components[2]), index + 5)
        default:
            return (nil, index + 2)
        }
    }

    // MARK: - OSC

    /// `rest` starts right after `ESC ]`. Terminated by BEL or `ESC \` (ST); returns nil — "not
    /// actually terminated" — when neither is found before the snapshot ends.
    private static func consumeOSC(_ rest: Substring) -> Substring? {
        var cursor = rest.startIndex
        while cursor < rest.endIndex {
            if rest[cursor] == "\u{07}" {
                return rest[rest.index(after: cursor)...]
            }
            if rest[cursor] == "\u{1B}" {
                let next = rest.index(after: cursor)
                if next < rest.endIndex, rest[next] == "\\" {
                    return rest[rest.index(after: next)...]
                }
            }
            cursor = rest.index(after: cursor)
        }
        return nil
    }
}
