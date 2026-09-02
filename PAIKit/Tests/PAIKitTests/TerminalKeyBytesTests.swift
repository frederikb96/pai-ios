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
