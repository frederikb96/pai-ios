import XCTest

@testable import PAIKit

/// The fixture router's answers that depend on what was asked: a note under its own id, the feed
/// under its filters. A router that answers one body for any request lets a screen that asks for
/// the wrong thing photograph fine.
final class PaiFixtureRoutesTests: XCTestCase {

    private func json(_ match: PaiFixtureURLProtocol.Match) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: match.body()) as? [String: Any])
    }

    // MARK: notes by id

    func testEachNoteAnswersUnderItsOwnId() throws {
        for id in [PaiFixtures.noteID, PaiFixtures.wikilinkNoteID, PaiFixtures.groceriesNoteID] {
            let match = PaiFixtureURLProtocol.route(method: "GET", path: "/api/notes/\(id)")
            XCTAssertEqual(match.status, 200)
            XCTAssertEqual(try json(match)["id"] as? String, id)
        }
    }

    /// The note the offline screenshots call uncached must not arrive as the rich note when the
    /// phone is online, or opening the wrong note would look the same as opening the right one.
    func testTheUncachedNoteIsNotTheRichNote() throws {
        let uncached = try json(
            PaiFixtureURLProtocol.route(method: "GET", path: "/api/notes/\(Route.fixtureUncachedNoteID)"))
        let rich = try json(PaiFixtureURLProtocol.route(method: "GET", path: "/api/notes/\(Route.fixtureNoteID)"))
        XCTAssertNotEqual(uncached["body"] as? String, rich["body"] as? String)
        XCTAssertNotEqual(uncached["name"] as? String, rich["name"] as? String)
    }

    func testAnUnknownNoteIdIsNotFoundForReadAndSave() {
        let read = PaiFixtureURLProtocol.route(method: "GET", path: "/api/notes/00000000-0000-0000-0000-000000000000")
        XCTAssertEqual(read.status, 404)
        let save = PaiFixtureURLProtocol.route(
            method: "PATCH", path: "/api/notes/00000000-0000-0000-0000-000000000000",
            body: Data(#"{"body":"x"}"#.utf8))
        XCTAssertEqual(save.status, 404)
    }

    func testASaveReadsBackAsTheNoteItWasSentTo() throws {
        let match = PaiFixtureURLProtocol.route(
            method: "PATCH", path: "/api/notes/\(PaiFixtures.groceriesNoteID)", body: Data(#"{"body":"new"}"#.utf8))
        let note = try json(match)
        XCTAssertEqual(note["id"] as? String, PaiFixtures.groceriesNoteID)
        XCTAssertEqual(note["body"] as? String, "new")
    }

    /// `containers` and `config` sit where a note id would; they stay their own routes.
    func testNoteCollectionRoutesAreNotReadAsNotes() {
        for path in ["/api/notes/containers", "/api/notes/config"] {
            XCTAssertEqual(PaiFixtureURLProtocol.route(method: "GET", path: path).status, 200, path)
        }
        let links = PaiFixtureURLProtocol.route(method: "GET", path: "/api/notes/\(PaiFixtures.noteID)/links")
        XCTAssertEqual(links.status, 200)
        let unknown = PaiFixtureURLProtocol.route(method: "GET", path: "/api/notes/nope/links")
        XCTAssertEqual(unknown.status, 404)
    }

    // MARK: the feed

    private func feed(_ query: [URLQueryItem]) throws -> [PaiNotification] {
        let match = PaiFixtureURLProtocol.route(method: "GET", path: "/api/notifications", query: query)
        XCTAssertEqual(match.status, 200)
        return try JSONDecoder().decode(NotificationsResponse.self, from: match.body()).notifications
    }

    func testTheFeedFiltersByTheScheduledParameter() throws {
        let all = try feed([])
        let only = try feed([URLQueryItem(name: "scheduled", value: "only")])
        let exclude = try feed([URLQueryItem(name: "scheduled", value: "exclude")])
        XCTAssertFalse(only.isEmpty)
        XCTAssertFalse(exclude.isEmpty)
        XCTAssertTrue(only.allSatisfy { $0.taskName != nil })
        XCTAssertTrue(exclude.allSatisfy { $0.taskName == nil })
        XCTAssertEqual(only.count + exclude.count, all.count)
    }

    func testTheScheduledFilterCombinesWithKind() throws {
        let rows = try feed([
            URLQueryItem(name: "kind", value: "alert"), URLQueryItem(name: "scheduled", value: "exclude"),
        ])
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.kind == .alert && $0.taskName == nil })
        XCTAssertTrue(
            try feed([URLQueryItem(name: "kind", value: "alert"), URLQueryItem(name: "scheduled", value: "only")])
                .isEmpty)
    }

    /// A quiet scheduled notification is stored read; the corpus keeps one, and one that pushed.
    func testTheCorpusHoldsAQuietAndABlockingScheduledRow() throws {
        let scheduled = try feed([URLQueryItem(name: "scheduled", value: "only")])
        XCTAssertTrue(scheduled.contains { !$0.isUnread })
        XCTAssertTrue(scheduled.contains { $0.isUnread && $0.title.hasPrefix("❌") })
    }

    // MARK: routes the screens fetch

    func testTheSchedulerStatusAndCanteenScreensHaveRoutesThatDecode() throws {
        func body(_ path: String) -> Data {
            let match = PaiFixtureURLProtocol.route(method: "GET", path: path)
            XCTAssertEqual(match.status, 200, path)
            return match.body()
        }
        let tasks = try JSONDecoder().decode(SchedulerTaskListResponse.self, from: body("/api/scheduler/tasks"))
        XCTAssertTrue(tasks.tasks.contains { $0.notifyPush == .blocking })
        XCTAssertTrue(tasks.tasks.contains { $0.notifyPush == .all })
        let status = try JSONDecoder().decode(StatusMessage.self, from: body("/api/status-message"))
        XCTAssertTrue(status.active)
        let canteen = try JSONDecoder().decode(CanteenEntriesResponse.self, from: body("/api/canteen/entries"))
        XCTAssertTrue(canteen.entries.contains { $0.menu != nil })
        XCTAssertTrue(canteen.entries.contains { $0.menuError != nil })
    }

    func testTheLaunchFlagsParse() {
        XCTAssertEqual(
            PaiFixtureLaunch.requestedNotificationSource(arguments: ["-PaiFixtureNotificationSource", "only"]),
            .scheduled)
        XCTAssertEqual(
            PaiFixtureLaunch.requestedNotificationSource(arguments: ["-PaiFixtureNotificationSource", "exclude"]),
            .notScheduled)
        XCTAssertNil(PaiFixtureLaunch.requestedNotificationSource(arguments: []))
        XCTAssertEqual(
            PaiFixtureLaunch.requestedScrollAnchor(arguments: ["-PaiFixtureScrollTo", "notesCache"]), "notesCache")
    }
}
