import XCTest

@testable import PAIKit

/// Where a live take's first words go when the draft changed after the take began: text put at
/// its end (answers to decisions) must survive the take's first write.
final class LiveTakeFirstWriteTests: XCTestCase {

    func testWordsFollowWhatWasAddedToTheDraftSinceTheTakeBegan() {
        let text = DraftHeal.firstLiveWrite(
            preVoiceText: "Thoughts.", currentDraftText: "Thoughts.\nD1 (A): yes", takeText: "stt-rec: and also")
        XCTAssertEqual(text, "Thoughts.\nD1 (A): yes\nstt-rec: and also")
    }

    func testWithNothingAddedTheWordsFollowTheStartAsBefore() {
        XCTAssertEqual(
            DraftHeal.firstLiveWrite(preVoiceText: "Thoughts.", currentDraftText: "Thoughts.", takeText: "stt-rec: x"),
            "Thoughts. stt-rec: x")
        XCTAssertEqual(
            DraftHeal.firstLiveWrite(preVoiceText: "", currentDraftText: "", takeText: "stt-rec: x"), "stt-rec: x")
    }

    /// A draft sent or cleared since is not something to bring back.
    func testADraftThatNoLongerHoldsTheStartIsNotResurrectedBeyondTheStart() {
        XCTAssertEqual(
            DraftHeal.firstLiveWrite(preVoiceText: "Thoughts.", currentDraftText: "", takeText: "stt-rec: x"),
            "Thoughts. stt-rec: x")
    }
}
