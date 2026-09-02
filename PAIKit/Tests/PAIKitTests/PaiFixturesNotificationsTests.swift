import Foundation
import XCTest

@testable import PAIKit

/// The notification fixtures, decoded into the models the app actually uses — same reasoning as
/// `PaiFixturesNotesTests`: a wrong key here is a free failure instead of a metered `Mac` run
/// that photographs a loading or error state and reads as a bug in the screen.
final class PaiFixturesNotificationsTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: PaiFixtures.data(json))
    }

    func testTheListDecodesAndTheUnreadCountMatchesTheUnreadRows() throws {
        let response = try decode(NotificationsResponse.self, PaiFixtures.notifications)
        let actuallyUnread = response.notifications.filter(\.isUnread).count
        XCTAssertEqual(response.unread, actuallyUnread)
    }

    /// The corpus exists to show one row of each kind the row view draws differently — losing one
    /// silently would still photograph a plausible-looking list.
    func testTheListCoversBothKindsAndBothReadStates() throws {
        let response = try decode(NotificationsResponse.self, PaiFixtures.notifications)
        XCTAssertTrue(response.notifications.contains { $0.kind == .agent && $0.isUnread })
        XCTAssertTrue(response.notifications.contains { $0.kind == .agent && !$0.isUnread })
        XCTAssertTrue(response.notifications.contains { $0.kind == .alert && $0.isUnread })
        XCTAssertTrue(response.notifications.contains { $0.kind == .alert && !$0.isUnread })
    }

    /// The one row a screenshot run's deep link exercises has to resolve to a message that is
    /// actually in the transcript fixture, or the jump silently does nothing and the screenshot
    /// proves nothing about it.
    func testTheAnchoredNotificationPointsAtARealTranscriptMessage() throws {
        let response = try decode(NotificationsResponse.self, PaiFixtures.notifications)
        let anchored = try XCTUnwrap(response.notifications.first { $0.anchor != nil })
        let messages = try decode([Message].self, PaiFixtures.transcript)
        XCTAssertTrue(messages.contains { $0.id == anchored.anchor?.messageId })
    }

    func testTheSummaryDecodesAndAgreesWithTheListsUnreadCount() throws {
        let summary = try decode(NotificationSummary.self, PaiFixtures.notificationsSummary)
        let response = try decode(NotificationsResponse.self, PaiFixtures.notifications)
        XCTAssertEqual(summary.unread, response.unread)
    }

    /// `GET /api/notifications/{id}` answers with a bare row, not the list wrapper — a shape bug
    /// there is exactly what `resolveAndOpenNotification` depends on to route a tapped push.
    func testTheDetailRouteDecodesAsABareRowMatchingTheListsFirstEntry() throws {
        let detail = try decode(PaiNotification.self, PaiFixtures.notificationDetail)
        let response = try decode(NotificationsResponse.self, PaiFixtures.notifications)
        XCTAssertEqual(detail, response.notifications.first)
    }
}
