import XCTest

@testable import PAIKit

/// The plus menu's session actions: the order they sit in, who gets which, and what each verdict
/// says. The view only draws what these return.
final class ComposerSessionActionsTests: XCTestCase {

    func testTheMenuListsCancelUndoSendSendNowMoveToBackgroundThenGrantSecretAccess() {
        let entries = ComposerSessionAction.entries(
            hasSession: true, offersProcessActions: true, canGrantSecretAccess: true)

        XCTAssertEqual(
            entries.map(\.title),
            ["Cancel", "Undo send", "Send now", "Move to background", "Grant Secret Access"])
    }

    func testAnUltraFastSessionKeepsCancelAndUndoButHasNoProcessToSendNowOrBackground() {
        let entries = ComposerSessionAction.entries(
            hasSession: true, offersProcessActions: false, canGrantSecretAccess: false)

        XCTAssertEqual(entries, [.cancel, .undoSend])
    }

    func testBeforeASessionExistsNoSessionActionIsOffered() {
        XCTAssertEqual(
            ComposerSessionAction.entries(hasSession: false, offersProcessActions: true, canGrantSecretAccess: false),
            [])
    }

    func testGrantSecretAccessFollowsTheServersVerdictAlone() {
        XCTAssertEqual(
            ComposerSessionAction.entries(hasSession: true, offersProcessActions: true, canGrantSecretAccess: false),
            [.cancel, .undoSend, .sendNow, .moveToBackground])
    }

    func testEveryRefusalReasonHasItsOwnSentence() {
        let sentences = [
            SendNowResponse.Reason.blocked, .promptHasDraft, .paneUnreadable, .notRunning,
        ].map { SendNowResponse(status: .refused, reason: $0).toastText }

        XCTAssertEqual(Set(sentences).count, 4, "\(sentences)")
        XCTAssertEqual(
            SendNowResponse(status: .refused, reason: .promptHasDraft).toastText,
            "Finish or clear the text in the terminal first")
    }

    func testASentVerdictSaysWhetherClaudeIsStillHoldingTheMessage() {
        XCTAssertEqual(SendNowResponse(status: .sent, delivered: [1]).toastText, "Sent now")
        XCTAssertNotEqual(SendNowResponse(status: .sent, stillQueued: [1]).toastText, "Sent now")
    }

    func testMovedAndNothingRunningAreDistinguishedAndARefusalCarriesTheWorkersWords() {
        XCTAssertEqual(MoveToBackgroundResponse(status: .moved, moved: ["t"]).toastText, "Moved to background")
        XCTAssertEqual(
            MoveToBackgroundResponse(status: .nothingRunning).toastText, "Nothing running in the foreground")
        XCTAssertEqual(
            MoveToBackgroundResponse(status: .refused, reason: "Background tasks are disabled in this session.")
                .toastText,
            "Background tasks are disabled in this session.")
    }
}
