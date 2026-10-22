import Foundation
import XCTest

@testable import PAIKit

final class SkillComposerTests: XCTestCase {
    private let names = ["dummy", "auto", "anthropic-skills:docx", "arc"]

    func testRowMarksTheLeadingChainAsRunningAndTypoAsAFix() {
        let items = SkillComposer.rowItems(text: "/dummy /auto then /arc and /autp", names: names, liveTake: false)
        XCTAssertEqual(items.map(\.label), ["\u{25B6} /dummy", "\u{25B6} /auto", "/arc", "did you mean /auto?"])
        XCTAssertEqual(items.map(\.isFix), [false, false, false, true])
    }

    func testRowIsEmptyDuringALiveTakeAndWithoutAListing() {
        XCTAssertEqual(SkillComposer.rowItems(text: "/dummy", names: names, liveTake: true), [])
        XCTAssertEqual(SkillComposer.rowItems(text: "/dummy", names: [], liveTake: false), [])
    }

    func testFixingEditsTheCurrentTextNotTheTextTheChipWasDrawnFor() throws {
        let drawn = try XCTUnwrap(
            SkillComposer.rowItems(text: "see /autp", names: names, liveTake: false).first)
        let later = "first line\nsee /autp now"
        XCTAssertEqual(SkillComposer.fixing(drawn, in: later, names: names), "first line\nsee /auto now")
        XCTAssertNil(SkillComposer.fixing(drawn, in: "see nothing", names: names))
    }

    func testCompletionStaysSilentWhereTheKeyboardOrATakeOwnsTheText() {
        let text = "hello /du"
        let caret = NSRange(location: 9, length: 0)
        func completion(
            _ selection: NSRange, marked: Bool = false, live: Bool = false, names: [String]? = nil
        ) -> SkillMentions.Completion? {
            SkillComposer.completion(
                text: text, selection: selection, names: names ?? self.names, hasMarkedText: marked, liveTake: live)
        }
        XCTAssertEqual(completion(caret)?.candidates, ["dummy"])
        XCTAssertNil(completion(caret, marked: true))
        XCTAssertNil(completion(caret, live: true))
        XCTAssertNil(
            SkillComposer.completion(
                text: "hello /du more", selection: NSRange(location: 9, length: 5), names: names,
                hasMarkedText: false, liveTake: false))
        XCTAssertEqual(
            SkillComposer.completion(
                text: "hello /du more", selection: NSRange(location: 9, length: 0), names: names,
                hasMarkedText: false, liveTake: false)?.candidates, ["dummy"])
        XCTAssertNil(completion(caret, names: []))
    }

    /// The edit handed to the text view must produce exactly the text `SkillMentions.replace`
    /// does, whether a space follows the token or not, with multi-unit characters before it.
    func testInsertionAppliedToTheTextEqualsTheWholeTextReplacement() throws {
        for text in ["\u{1F600} hi /du", "\u{1F600} /du and more", "/du\nnext", "/du "] {
            let source = text as NSString
            let start = source.range(of: "/du").location
            let range = NSRange(location: start, length: 3)
            let insertion = SkillComposer.insertion(replacing: range, with: "dummy", in: text)
            let applied = source.replacingCharacters(in: insertion.range, with: insertion.replacement)
            let whole = SkillMentions.replace(range, in: text, with: "dummy")
            XCTAssertEqual(applied, whole.text, text)
            XCTAssertEqual(insertion.caret, whole.caret, text)
        }
    }
}
