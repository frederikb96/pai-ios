import XCTest

@testable import PAIKit

final class TerminalKeyBytesTests: XCTestCase {

    func testEachArrowIsItsOwnDistinctCsiSequence() {
        let directions: [TerminalArrowDirection] = [.up, .down, .left, .right]
        let sequences = directions.map(TerminalKeyBytes.arrow)

        XCTAssertEqual(Set(sequences).count, sequences.count, "a copy-paste could silently alias two directions")
        for sequence in sequences {
            XCTAssertTrue(sequence.hasPrefix("\u{1b}["), "an arrow is a CSI sequence: ESC [")
        }
    }

    /// The one invariant this whole feature depends on: a real submit and a newline that must
    /// NOT submit can never be the same bytes, or the pane could not tell them apart either.
    func testSubmitAndPaneNewlineAreDifferentPayloads() {
        XCTAssertNotEqual(
            TerminalKeyBytes.submit, TerminalKeyBytes.paneNewline,
            "submit and the non-submitting newline must never collapse to the same bytes")
    }

    func testControlChordIsCaseInsensitiveAndMatchesTheClassicAsciiTable() {
        let upper = TerminalKeyBytes.controlChord(for: "B")
        let lower = TerminalKeyBytes.controlChord(for: "b")

        XCTAssertEqual(upper, lower, "Control-B and Control-b are the same chord on every terminal")
        XCTAssertEqual(upper?.first?.asciiValue, 2, "Control-B is STX, chr(2)")
    }

    func testControlChordRejectsWhateverIsNotAnAsciiLetter() {
        XCTAssertNil(TerminalKeyBytes.controlChord(for: "1"))
        XCTAssertNil(TerminalKeyBytes.controlChord(for: "["))
        XCTAssertNil(TerminalKeyBytes.controlChord(for: "é"))
    }
}
