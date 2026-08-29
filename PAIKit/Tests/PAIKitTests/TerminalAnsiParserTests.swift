import XCTest

@testable import PAIKit

final class TerminalAnsiParserTests: XCTestCase {

    private let esc = "\u{1B}"

    /// Plain text with no escapes at all must survive as one run — the common case, and the one
    /// every other test's "before/after" text relies on rendering unchanged.
    func testPlainTextIsOneRunWithDefaultStyle() {
        let screen = TerminalAnsiParser.parse("hello world")

        XCTAssertEqual(screen.lines.count, 1)
        XCTAssertEqual(screen.lines[0].runs, [TerminalRun(text: "hello world", style: TerminalStyle())])
    }

    /// The 16-color table, both halves: normal (30-37) and the bright variant (90-97), which the
    /// two share one representation for (0-15) rather than two unrelated ones.
    func testStandardAndBrightForegroundColorsMapToOneSixteenSlotPalette() {
        let normal = TerminalAnsiParser.parse("\(esc)[31mred\(esc)[0m")
        let bright = TerminalAnsiParser.parse("\(esc)[91mbright red\(esc)[0m")

        XCTAssertEqual(normal.lines[0].runs.first?.style.foreground, .standard(1))
        XCTAssertEqual(bright.lines[0].runs.first?.style.foreground, .standard(9))
    }

    /// Background colors and foreground colors are independent slots — a refactor that shared one
    /// variable for "the active color" would make setting a background silently overwrite an
    /// already-set foreground.
    func testForegroundAndBackgroundColorsAreIndependent() {
        let screen = TerminalAnsiParser.parse("\(esc)[31;44mtext")

        let style = screen.lines[0].runs[0].style
        XCTAssertEqual(style.foreground, .standard(1))
        XCTAssertEqual(style.background, .standard(4))
    }

    /// SGR 39/49 clear only their own channel, leaving the other and any bold/italic/underline
    /// attributes exactly as they were — distinct from a full SGR 0 reset.
    func testDefaultForegroundAndBackgroundClearOnlyTheirOwnChannel() {
        let screen = TerminalAnsiParser.parse("\(esc)[1;31;44mstyled\(esc)[39mno fg\(esc)[49mno fg or bg")

        let runs = screen.lines[0].runs
        XCTAssertEqual(runs[0].style, TerminalStyle(foreground: .standard(1), background: .standard(4), bold: true))
        XCTAssertEqual(runs[1].style, TerminalStyle(foreground: nil, background: .standard(4), bold: true))
        XCTAssertEqual(runs[2].style, TerminalStyle(foreground: nil, background: nil, bold: true))
    }

    /// A style change mid-line must start a new run rather than silently repainting text already
    /// emitted, and text sharing one style must stay coalesced into a single run rather than one
    /// run per character.
    func testStyleChangeSplitsIntoDistinctRuns() {
        let screen = TerminalAnsiParser.parse("plain\(esc)[1mbold text\(esc)[0mplain again")

        let runs = screen.lines[0].runs
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs[0].text, "plain")
        XCTAssertFalse(runs[0].style.bold)
        XCTAssertEqual(runs[1].text, "bold text")
        XCTAssertTrue(runs[1].style.bold)
        XCTAssertEqual(runs[2].text, "plain again")
        XCTAssertFalse(runs[2].style.bold)
    }

    /// SGR 0 clears every attribute at once, not just color — a common way to get this wrong is
    /// to reset color while leaving bold/underline set from an earlier code.
    func testFullResetClearsEveryAttribute() {
        let screen = TerminalAnsiParser.parse("\(esc)[1;4;31mstyled\(esc)[0mplain")

        XCTAssertEqual(screen.lines[0].runs[1].style, TerminalStyle())
    }

    /// The 256-color and truecolor extended forms, both of which consume more than one parameter
    /// past the `38`/`48` selector — the case most likely to desync a positional parameter walk.
    func testExtendedColorFormsAreParsed() {
        let indexed = TerminalAnsiParser.parse("\(esc)[38;5;196mindexed")
        let trueColor = TerminalAnsiParser.parse("\(esc)[38;2;255;128;0mtruecolor")

        XCTAssertEqual(indexed.lines[0].runs[0].style.foreground, .indexed(196))
        XCTAssertEqual(trueColor.lines[0].runs[0].style.foreground, .trueColor(255, 128, 0))
    }

    /// An extended-color selector cut short by the end of the parameter list must not consume (or
    /// misread) whatever comes after it — losing sync here would silently corrupt every SGR code
    /// in the rest of the line.
    func testTruncatedExtendedColorDoesNotDesyncSubsequentCodes() {
        let screen = TerminalAnsiParser.parse("\(esc)[38;5mtext\(esc)[31mred")

        XCTAssertNil(screen.lines[0].runs[0].style.foreground, "an incomplete 38;5 form invented a color")
        XCTAssertEqual(screen.lines[0].runs[1].style.foreground, .standard(1), "the following 31 was misread")
    }

    /// A CSI sequence tmux can still emit that is not SGR (cursor positioning, erase-in-line) must
    /// vanish without leaving stray characters or corrupting the run it interrupts — text on
    /// either side must still join as one run, since no style actually changed.
    func testNonSgrCsiIsDroppedWithoutLeavingArtifacts() {
        let screen = TerminalAnsiParser.parse("before\(esc)[5;10Hafter")

        XCTAssertEqual(screen.lines.count, 1)
        XCTAssertEqual(screen.lines[0].runs, [TerminalRun(text: "beforeafter", style: TerminalStyle())])
    }

    /// The one truncation case explicitly flagged as easy to get wrong: an escape sequence cut
    /// off by the end of the snapshot. It must survive as literal text, not vanish — losing
    /// characters is worse than losing a color.
    func testTruncatedCsiAtEndOfSnapshotIsKeptAsLiteralText() {
        let screen = TerminalAnsiParser.parse("visible text\(esc)[31")

        let allText = screen.lines[0].runs.map(\.text).joined()
        XCTAssertEqual(allText, "visible text\(esc)[31")
    }

    /// A lone ESC not followed by `[` or `]` (nothing this parser recognises as an introducer)
    /// must not swallow the character right after it.
    func testLoneEscapeKeepsTheFollowingCharacter() {
        let screen = TerminalAnsiParser.parse("a\(esc)bc")

        XCTAssertEqual(screen.lines[0].runs.map(\.text).joined(), "a\(esc)bc")
    }

    /// An OSC sequence (a hyperlink, in practice) terminated by BEL must disappear entirely,
    /// leaving the text around it joined as normal.
    func testOscTerminatedByBelIsDropped() {
        let screen = TerminalAnsiParser.parse("before\(esc)]8;;https://example.com\u{07}after")

        XCTAssertEqual(screen.lines[0].runs.map(\.text).joined(), "beforeafter")
    }

    /// The same, terminated by ST (`ESC \`) instead of BEL — the other valid terminator.
    func testOscTerminatedByStringTerminatorIsDropped() {
        let screen = TerminalAnsiParser.parse("before\(esc)]8;;https://example.com\(esc)\\after")

        XCTAssertEqual(screen.lines[0].runs.map(\.text).joined(), "beforeafter")
    }

    /// An OSC sequence with no terminator before the snapshot ends must be kept as text rather
    /// than swallowed on the assumption it would eventually close — the same "never lose
    /// characters" rule as a truncated CSI.
    func testUnterminatedOscIsKeptAsLiteralText() {
        let input = "before\(esc)]8;;https://example.com"
        let screen = TerminalAnsiParser.parse(input)

        XCTAssertEqual(screen.lines[0].runs.map(\.text).joined(), input)
    }

    /// A style set before a newline must still apply after it — tmux's capture does not re-emit
    /// an SGR code at every row, only where an attribute actually changes. A parser that reset
    /// style per line would silently discolor the second line of any multi-line colored block.
    func testStyleCarriesAcrossANewline() {
        let screen = TerminalAnsiParser.parse("\(esc)[32mgreen line one\nstill green line two")

        XCTAssertEqual(screen.lines.count, 2)
        XCTAssertEqual(screen.lines[0].runs[0].style.foreground, .standard(2))
        XCTAssertEqual(screen.lines[1].runs[0].style.foreground, .standard(2))
    }

    /// Line count must match ordinary string-splitting semantics — N newlines produce N+1 lines,
    /// including a trailing empty one — so a view iterating `screen.lines` never silently drops
    /// or invents a row relative to what plain `\n`-splitting the same text would give.
    func testLineSplittingMatchesPlainNewlineSplitCount() {
        let screen = TerminalAnsiParser.parse("one\ntwo\n")

        XCTAssertEqual(screen.lines.count, 3)
        XCTAssertEqual(screen.lines[2].runs, [])
    }

    /// A bare `\r` (which capture-pane's output never actually contains — rows are separated by
    /// `\n` alone) must not surface as a visible character if it ever does appear.
    func testBareCarriageReturnIsDropped() {
        let screen = TerminalAnsiParser.parse("a\rb")

        XCTAssertEqual(screen.lines[0].runs.map(\.text).joined(), "ab")
    }

    func testEmptyInputYieldsOneEmptyLine() {
        let screen = TerminalAnsiParser.parse("")

        XCTAssertEqual(screen.lines, [TerminalLine(runs: [])])
    }
}
