import XCTest

@testable import PAIKit

/// What a finger on the live page does. The page is 1000x500 CSS px in a 400x400 box, so it is
/// fitted at 0.4 and letterboxed top and bottom (100 pt each): a point on the letterbox is not on
/// the page, and a tap there must not click.
@MainActor
final class BrowserGestureInterpreterTests: XCTestCase {

    private func makeInterpreter() -> (BrowserGestureInterpreter, () -> [BrowserInput]) {
        let interpreter = BrowserGestureInterpreter()
        var sent: [BrowserInput] = []
        interpreter.send = { sent.append($0) }
        interpreter.setFrameSize(BrowserSize(w: 1000, h: 500))
        interpreter.setBoxSize(BrowserSize(w: 400, h: 400))
        return (interpreter, { sent })
    }

    func testATapClicksTheMappedPagePoint() async {
        let (gestures, sent) = makeInterpreter()
        gestures.touchDown(id: 1, x: 200, y: 200)
        gestures.touchUp(id: 1, x: 200, y: 200)
        XCTAssertEqual(sent(), [.mouse(action: .click, x: 500, y: 250, button: .left)])
    }

    func testATapOnTheLetterboxDoesNotClick() async {
        let (gestures, sent) = makeInterpreter()
        gestures.touchDown(id: 1, x: 200, y: 50)
        gestures.touchUp(id: 1, x: 200, y: 50)
        XCTAssertEqual(sent(), [])
    }

    func testADragScrollsTheOppositeWayInPagePixelsAndDoesNotClick() async {
        let (gestures, sent) = makeInterpreter()
        gestures.touchDown(id: 1, x: 200, y: 200)
        gestures.touchMoved(id: 1, x: 200, y: 180)
        gestures.touchMoved(id: 1, x: 200, y: 160)
        gestures.touchUp(id: 1, x: 200, y: 160)
        XCTAssertEqual(
            sent(),
            [
                .wheel(x: 500, y: 250, dx: 0, dy: 50),
                .wheel(x: 500, y: 250, dx: 0, dy: 50),
            ])
    }

    func testAWobbleUnderTheSlopStillTaps() async {
        let (gestures, sent) = makeInterpreter()
        gestures.touchDown(id: 1, x: 200, y: 200)
        gestures.touchMoved(id: 1, x: 205, y: 203)
        gestures.touchUp(id: 1, x: 205, y: 203)
        XCTAssertEqual(sent(), [.mouse(action: .click, x: 500, y: 250, button: .left)])
    }

    func testALongPressRightClicksAndTheLiftThatFollowsDoesNotAlsoClick() async {
        let (gestures, sent) = makeInterpreter()
        gestures.touchDown(id: 1, x: 200, y: 200)
        gestures.longPressFired()
        gestures.touchUp(id: 1, x: 200, y: 200)
        XCTAssertEqual(sent(), [.mouse(action: .click, x: 500, y: 250, button: .right)])
    }

    func testPinchingZoomsAndNothingFiresWhenTheFingersLift() async {
        let (gestures, sent) = makeInterpreter()
        gestures.touchDown(id: 1, x: 180, y: 200)
        gestures.touchDown(id: 2, x: 220, y: 200)
        gestures.touchMoved(id: 1, x: 140, y: 200)
        gestures.touchMoved(id: 2, x: 260, y: 200)
        XCTAssertEqual(gestures.transform.zoom, 3, accuracy: 0.0001)
        gestures.touchUp(id: 2, x: 260, y: 200)
        // The finger left behind neither clicks nor scrolls.
        gestures.touchMoved(id: 1, x: 100, y: 100)
        gestures.touchUp(id: 1, x: 100, y: 100)
        XCTAssertEqual(sent(), [])
    }

    func testAZoomedTapLandsOnThePointUnderTheFinger() async {
        let (gestures, sent) = makeInterpreter()
        gestures.zoomIn()
        gestures.touchDown(id: 1, x: 200, y: 200)
        gestures.touchUp(id: 1, x: 200, y: 200)
        // Zooming about the centre leaves the page centre under the centre of the box.
        guard case .mouse(.click, let x, let y, .left)? = sent().first else { return XCTFail("no click") }
        XCTAssertEqual(x, 500, accuracy: 0.0001)
        XCTAssertEqual(y, 250, accuracy: 0.0001)
    }

    func testFitPageUndoesZoomAndPan() async {
        let (gestures, _) = makeInterpreter()
        gestures.zoomIn()
        gestures.zoomIn()
        gestures.fitPage()
        XCTAssertEqual(
            gestures.transform, BrowserGeometry.clamp(.identity, frame: gestures.frameSize, box: gestures.boxSize))
    }
}
