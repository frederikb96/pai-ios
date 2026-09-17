import XCTest

@testable import PAIKit

final class CallDraftTextTests: XCTestCase {

    /// An older copy of the draft arriving from elsewhere — the same base with less of the
    /// preview — must not turn the preview into typed text, or it outlives the send.
    func testAStaleCopyOfTheDraftNeverBecomesPartOfTheBase() {
        var draft = CallDraftText(base: "")
        XCTAssertEqual(draft.draft(forPreview: "hello there general"), "stt-rec: hello there general")

        draft.adopt(currentDraft: "stt-rec: hello there")
        let afterSend = draft.baseSent(draft.base)

        XCTAssertEqual(draft.base, "")
        XCTAssertEqual(afterSend, "stt-rec: hello there general")
        XCTAssertEqual(draft.draft(forPreview: ""), "")
    }

    /// Text typed ahead of the preview while a send is on its way is newer than the send, so it
    /// stays in the draft once the send succeeds.
    func testTextTypedWhileASendIsInFlightSurvivesTheSend() {
        var draft = CallDraftText(base: "pasted logs")
        _ = draft.draft(forPreview: "check these")
        let sentBase = draft.base

        draft.adopt(currentDraft: "pasted logs and a note stt-rec: check these")
        _ = draft.draft(forPreview: "")
        let afterSend = draft.baseSent(sentBase)

        XCTAssertEqual(afterSend, "and a note")
        XCTAssertEqual(draft.message(turnText: "stt-rec: next"), "and a note stt-rec: next")
    }

    /// Text typed *ahead of* the sent base while the send is still in flight is just as common as
    /// text typed after it — the composer stays editable the whole time a send is out — so the
    /// sent text must be removed wherever it sits, not only when it is still the draft's prefix.
    func testTextTypedBeforeTheSentBaseWhileASendIsInFlightSurvivesTheSend() {
        var draft = CallDraftText(base: "pasted logs")
        _ = draft.draft(forPreview: "check these")
        let sentBase = draft.base

        draft.adopt(currentDraft: "URGENT: pasted logs stt-rec: check these")
        _ = draft.draft(forPreview: "")
        let afterSend = draft.baseSent(sentBase)

        XCTAssertEqual(afterSend, "URGENT:")
        XCTAssertEqual(draft.message(turnText: "stt-rec: next"), "URGENT: stt-rec: next")
    }
}
