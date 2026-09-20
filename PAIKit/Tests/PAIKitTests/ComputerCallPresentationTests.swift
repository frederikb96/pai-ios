import XCTest

@testable import PAIKit

/// What the voice screen shows, and which of its controls do anything — the one derivation the
/// screen is built on, so every way it could contradict itself is a case here rather than
/// something only a device could find.
final class ComputerCallPresentationTests: XCTestCase {

    private func make(
        connectionState: ComputerCallConnectionState = .active,
        busOwner: VoiceBusOwner = .computer,
        phase: String = "listening",
        sessionId: String? = nil,
        sessionName: String? = nil,
        isSpeaking: Bool = false
    ) -> ComputerCallPresentation {
        ComputerCallPresentation.make(
            connectionState: connectionState, busOwner: busOwner, phase: phase,
            sessionId: sessionId, sessionName: sessionName, isSpeaking: isSpeaking)
    }

    /// The face follows the bus, and only the bus — nothing this screen asks for, and nothing it
    /// remembers about where the call has been.
    func testTheCallFaceNeedsBothTheOwnerAndAnId() {
        let inCall = make(busOwner: .call, phase: "wake", sessionId: "s-1", sessionName: "Deploy")
        XCTAssertEqual(inCall.face, .call(sessionId: "s-1", sessionName: "Deploy"))

        // `session_id` is present "only when it is `call`" per the protocol doc — so an owner
        // that says `call` with no id is a frame this client cannot act on. Falling back to the
        // Computer face keeps the screen coherent; showing a nameless, idless call face would
        // offer controls addressed at nothing.
        XCTAssertEqual(make(busOwner: .call, sessionId: nil).face, .computer)
    }

    /// The name is the client's own lookup, so a session this device has not listed yet is a
    /// face with no name rather than no face.
    func testACallIntoAnUnlistedSessionStillShowsTheCallFace() {
        XCTAssertEqual(
            make(busOwner: .call, phase: "wake", sessionId: "s-9", sessionName: nil).face,
            .call(sessionId: "s-9", sessionName: nil))
    }

    /// A take is open or it is not — so the control that opens one and the two that close one
    /// can never be offered together.
    func testStartAndTheTakeEndingControlsAreMutuallyExclusive() {
        let recording = make(busOwner: .call, phase: "recording", sessionId: "s-1")
        XCTAssertTrue(recording.enabledCommands.isSuperset(of: [.stop, .send]))
        XCTAssertFalse(recording.enabledCommands.contains(.start))

        let quiet = make(busOwner: .call, phase: "wake", sessionId: "s-1")
        XCTAssertTrue(quiet.enabledCommands.contains(.start))
        XCTAssertTrue(quiet.enabledCommands.isDisjoint(with: [.stop, .send]))
    }

    /// A reply is spoken during the quiet phase too, and leaving for Computer costs nothing from
    /// either phase — both are wrong to gate on a take being open.
    func testSkipAndLeavingApplyInEitherPhase() {
        for phase in ["recording", "wake"] {
            let presentation = make(busOwner: .call, phase: phase, sessionId: "s-1")
            XCTAssertTrue(
                presentation.enabledCommands.isSuperset(of: [.skip, .listen]),
                "expected skip and listen in phase \(phase)")
        }
    }

    /// A phase a newer backend invents must not silently enable the pair that ends a take: this
    /// build cannot know whether one is open, and offering Send against no take sends nothing
    /// while looking like it sent something.
    func testAnUnknownPhaseWillNotOfferToEndATakeItCannotSee() {
        let presentation = make(busOwner: .call, phase: "transcribing", sessionId: "s-1")
        XCTAssertTrue(presentation.enabledCommands.isDisjoint(with: [.stop, .send]))
        XCTAssertTrue(presentation.enabledCommands.contains(.start))
    }

    /// Every one of these frames is dropped by the session while the socket is not active, so an
    /// enabled control here is one that does nothing and says nothing — the exact moment a
    /// confirmation matters most.
    func testNothingIsOfferedWhileTheConnectionIsNotActive() {
        for state in [ComputerCallConnectionState.idle, .connecting, .reconnecting] {
            let presentation = make(
                connectionState: state, busOwner: .call, phase: "recording", sessionId: "s-1")
            XCTAssertTrue(presentation.enabledCommands.isEmpty, "expected no controls in \(state)")
        }
    }

    /// Computer's own engine acts on none of the call's controls, so offering one would be a
    /// button whose frame is read and discarded server-side.
    func testTheComputerFaceOffersNoCallControls() {
        XCTAssertTrue(make(phase: "listening").enabledCommands.isEmpty)
    }

    /// A blank line under a live microphone reads as a screen that has stopped working, so every
    /// reachable combination says something.
    func testTheStatusLineIsNeverEmpty() {
        let states: [ComputerCallConnectionState] = [.idle, .connecting, .reconnecting, .active]
        let phases = ["listening", "wake", "recording", "", "something-new"]
        for state in states {
            for owner in [VoiceBusOwner.computer, .call] {
                for phase in phases {
                    for speaking in [true, false] {
                        let presentation = make(
                            connectionState: state, busOwner: owner, phase: phase,
                            sessionId: "s-1", isSpeaking: speaking)
                        XCTAssertFalse(
                            presentation.status.isEmpty,
                            "empty status for \(state)/\(owner)/\(phase)/\(speaking)")
                    }
                }
            }
        }
    }
}

/// A call connected straight into a session (`hello.connect_session`) never had Computer on its
/// bus at all — the backend answers "computer listen" there by closing the connection.
extension ComputerCallPresentationTests {
    func testACallWithNoComputerBehindItDoesNotOfferToGoBackToOne() {
        let direct = ComputerCallPresentation.make(
            connectionState: .active, busOwner: .call, phase: "wake", sessionId: "s-1",
            sessionName: "Deploy", isSpeaking: false, canReturnToComputer: false)

        XCTAssertFalse(direct.enabledCommands.contains(.listen))
        // Everything else is untouched: the take controls are about the take, not about how the
        // call was reached.
        XCTAssertTrue(direct.enabledCommands.isSuperset(of: [.skip, .start]))
    }

    func testACallThatReachedComputerFirstStillOffersTheWayBack() {
        let viaComputer = ComputerCallPresentation.make(
            connectionState: .active, busOwner: .call, phase: "wake", sessionId: "s-1",
            sessionName: "Deploy", isSpeaking: false, canReturnToComputer: true)

        XCTAssertTrue(viaComputer.enabledCommands.contains(.listen))
    }
}
