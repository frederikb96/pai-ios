import XCTest

@testable import PAIKit

final class SessionMovedTests: XCTestCase {

    private func machine(_ slug: String, _ name: String) -> Machine {
        Machine(
            slug: slug, displayName: name, online: true, lastSeenAt: nil, ingestEnabled: true,
            capabilities: .init(fastSessions: false, reboot: false, shell: false, rcLocal: false),
            sessionTypes: [])
    }

    private var machines: [Machine] { [machine("vm", "Cloud"), machine("laptop", "Laptop")] }

    /// Decoded from the wire shape, since `transferred_at` has no setter.
    private func moved(at: String? = "2026-10-05T12:30:00.123456+00:00") -> Session {
        let movedAt = at.map { #","transferred_at":"\#($0)""# } ?? ""
        let json = """
            {"id":"src","session_type":"claude","status":"active","state":"closed","blocker":null,
             "title":null,"title_locked":null,"initial_message":null,"session_tokens":0,
             "claude_session_id":"c1","cse_id":null,"created_at":null,"updated_at":null,
             "last_activity_at":null,"working_dir":null,"agent":"vm",
             "transferred_to_session_id":"dst"\(movedAt)}
            """
        return try! JSONDecoder().decode(Session.self, from: Data(json.utf8))
    }

    func testPillAppearsOnlyForAMovedSession() {
        let target = SessionFixture.make(id: "dst", agent: "laptop")
        XCTAssertEqual(
            SessionMoved.pillText(for: moved(), target: target, machines: machines), "Moved to Laptop")
        XCTAssertNil(
            SessionMoved.pillText(for: SessionFixture.make(id: "plain"), target: nil, machines: machines))
    }

    func testMachineFallsBackToTheOtherMachineWhenTheTargetIsNotLoaded() {
        XCTAssertEqual(SessionMoved.machineName(for: moved(), target: nil, machines: machines), "Laptop")
        let three = machines + [machine("desk", "Desk")]
        XCTAssertEqual(SessionMoved.machineName(for: moved(), target: nil, machines: three), "another machine")
    }

    func testBannerNamesTheMachineAndTheLocalTime() throws {
        let berlin = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let text = SessionMoved.bannerText(
            for: moved(), target: nil, machines: machines, timeZone: berlin,
            locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertTrue(text?.hasPrefix("This conversation moved to Laptop on ") ?? false, text ?? "nil")
        XCTAssertTrue(text?.contains("2:30") ?? false, "12:30 UTC is 2:30 PM in Berlin: \(text ?? "nil")")
        XCTAssertTrue(text?.hasSuffix(".") ?? false)
        XCTAssertEqual(
            SessionMoved.bannerText(for: moved(at: nil), target: nil, machines: machines),
            "This conversation moved to Laptop.")
        XCTAssertNil(SessionMoved.bannerText(for: SessionFixture.make(), target: nil, machines: machines))
    }

    func testComposerPointsAtTheOtherMachine() {
        XCTAssertEqual(
            SessionMoved.composerText(for: moved(), target: nil, machines: machines),
            "Moved to Laptop — open it there")
        XCTAssertNil(SessionMoved.composerText(for: SessionFixture.make(), target: nil, machines: machines))
    }
}

/// The live status event carries the transfer fields, so the marker moves without a poll.
@MainActor
final class SessionMovedLiveStatusTests: XCTestCase {

    func testStatusEventDecodesBothTransferFields() async throws {
        let json = Data(
            """
            {"status":"active","state":null,"blocker":null,
             "transferred_to_session_id":"dst","transferred_at":"2026-10-05T12:30:00.123456+00:00"}
            """.utf8)
        let event = try JSONDecoder().decode(SseStatusEvent.self, from: json)
        XCTAssertEqual(event.transferredToSessionId, "dst")
        XCTAssertEqual(event.transferredAt, "2026-10-05T12:30:00.123456+00:00")
    }

    func testStatusEventMovesTheListRowAndReversingClearsIt() async throws {
        let store = TranscriptStore()
        let moved = try JSONDecoder().decode(
            SseStatusEvent.self,
            from: Data(
                #"{"status":"active","state":null,"blocker":null,"transferred_to_session_id":"dst","transferred_at":"2026-10-05T12:30:00+00:00"}"#
                    .utf8))
        store.applySseStatus(sessionId: "s1", event: moved)
        let status = try XCTUnwrap(store.liveStatus["s1"])
        XCTAssertEqual(status.transfer, SessionMoved.Mark(toSessionId: "dst", at: "2026-10-05T12:30:00+00:00"))

        let base = SessionFixture.make(id: "s1")
        let applied = base.withLiveStatus(
            state: nil, blocker: nil, turnState: nil, displayState: nil, activityCounts: nil,
            secretGrantable: nil, secretPrompt: nil, liveModel: nil, transfer: status.transfer)
        XCTAssertTrue(SessionMoved.isMoved(applied))
        XCTAssertEqual(applied.transferredAt, "2026-10-05T12:30:00+00:00")

        let reversed = applied.withLiveStatus(
            state: nil, blocker: nil, turnState: nil, displayState: nil, activityCounts: nil,
            secretGrantable: nil, secretPrompt: nil, liveModel: nil,
            transfer: SessionMoved.Mark(toSessionId: nil, at: nil))
        XCTAssertFalse(SessionMoved.isMoved(reversed))
        XCTAssertNil(reversed.transferredAt)

        // No mark supplied (a close, a pin) leaves the fields alone.
        let untouched = applied.withLiveStatus(
            state: nil, blocker: nil, turnState: nil, displayState: nil, activityCounts: nil,
            secretGrantable: nil, secretPrompt: nil, liveModel: nil)
        XCTAssertTrue(SessionMoved.isMoved(untouched))
    }
}
