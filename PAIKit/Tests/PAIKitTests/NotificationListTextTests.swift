import XCTest

@testable import PAIKit

/// What the notification list shows of a row: the title led by the backend's run slug, and an
/// agent body without its decision card lines.
final class NotificationListTextTests: XCTestCase {

    private func row(
        kind: PaiNotificationKind = .agent, title: String = "❓ Which one?", body: String = "b", runSlug: String? = nil
    ) -> PaiNotification {
        PaiNotification(
            id: "n", kind: kind, title: title, body: body, createdAt: "2026-01-01T00:00:00Z", readAt: nil,
            sessionId: nil, sessionTitle: nil, anchor: nil, alert: nil, taskId: nil, taskName: nil, runSlug: runSlug)
    }

    func testTheTitleIsLedByTheSlugTheBackendNamed() {
        XCTAssertEqual(row(runSlug: "HermesEngine").listTitle, "HermesEngine · ❓ Which one?")
        XCTAssertEqual(row().listTitle, "❓ Which one?")
    }

    func testTheSlugDecodesFromTheWireAndSurvivesARebuild() throws {
        let page = try JSONDecoder().decode(
            NotificationsResponse.self, from: PaiFixtures.notificationsPage(kind: nil, scheduled: nil))
        let slugged = try XCTUnwrap(page.notifications.first { $0.runSlug != nil })
        XCTAssertEqual(slugged.listTitle, "Nightlybackup · ❌ Nightly backup stopped")
        XCTAssertEqual(slugged.with(readAt: "2026-01-02T00:00:00Z", alert: nil).runSlug, "Nightlybackup")
        XCTAssertEqual(page.notifications.filter { $0.runSlug == nil }.count, page.notifications.count - 1)
    }

    func testAnAgentBodyLosesItsCardLinesAndAnAlertBodyStaysAsSent() {
        let body = "The migration is ready.\n\n{{D3}}\n\nThe rest."
        let shown = row(body: body).listBody
        XCTAssertFalse(shown.contains("{{D3}}"))
        XCTAssertTrue(shown.contains("The migration is ready."))
        XCTAssertTrue(shown.contains("The rest."))
        XCTAssertEqual(row(kind: .alert, body: body).listBody, body)
    }

    func testAMarkerInsideACodeFenceStaysText() {
        let body = "```\n{{D3}}\n```"
        XCTAssertEqual(row(body: body).listBody, body)
    }
}
