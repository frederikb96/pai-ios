import XCTest

@testable import PAIKit

/// A deep link is parsed from something the app did not write — an APNs payload assembled by the
/// backend, or a URL a person typed into a shortcut. Everything here is about the shapes that
/// arrive wrong, because the shapes that arrive right are the ones nobody ever debugs.
final class DeepLinkTests: XCTestCase {

    // MARK: Payloads

    func testReadsASessionFromAPushPayload() {
        XCTAssertEqual(
            DeepLink.from(payload: [DeepLink.sessionIDKey: "abc"]), .session(id: "abc"))
    }

    func testReadsANoteFromAPushPayload() {
        XCTAssertEqual(DeepLink.from(payload: [DeepLink.noteIDKey: "n1"]), .note(id: "n1"))
    }

    /// The backend sends `aps` and whatever else it likes in the same flat dictionary. A payload
    /// carrying no link of ours has to read as "no link", not as a link to something arbitrary.
    func testAPayloadWithNoLinkKeysIsNotALink() {
        XCTAssertNil(DeepLink.from(payload: ["aps": "{}", "unrelated": "value"]))
    }

    /// An empty string is what a template renders when the value it was given was absent. Treated
    /// as a real id it opens a session that cannot exist, and the screen reports a load failure
    /// rather than the notification simply not being a link.
    func testAnEmptyIdIsNotALink() {
        XCTAssertNil(DeepLink.from(payload: [DeepLink.sessionIDKey: ""]))
    }

    func testASessionWinsOverANoteWhenAPayloadNamesBoth() {
        XCTAssertEqual(
            DeepLink.from(payload: [DeepLink.sessionIDKey: "s", DeepLink.noteIDKey: "n"]),
            .session(id: "s"))
    }

    /// Every push this app currently sends for an agent or alert notification carries only this
    /// key — see `DeepLink.notification`'s doc comment.
    func testReadsANotificationFromAPushPayload() {
        XCTAssertEqual(
            DeepLink.from(payload: [DeepLink.notificationIDKey: "n1"]), .notification(id: "n1"))
    }

    /// The notification id wins over a session id on the same payload, matching how a session
    /// already wins over a note — the most specific, most recently-added key is checked first.
    func testANotificationWinsOverASessionWhenAPayloadNamesBoth() {
        XCTAssertEqual(
            DeepLink.from(payload: [DeepLink.notificationIDKey: "n1", DeepLink.sessionIDKey: "s1"]),
            .notification(id: "n1"))
    }

    func testReadsAMessageIDAlongsideASession() {
        XCTAssertEqual(
            DeepLink.from(payload: [DeepLink.sessionIDKey: "s1", DeepLink.messageIDKey: "42"]),
            .session(id: "s1", messageID: 42))
    }

    /// A malformed or non-numeric message id must not fail the whole link — the session is still
    /// real and worth opening, just without a jump.
    func testAMalformedMessageIDIsIgnoredRatherThanFailingTheLink() {
        XCTAssertEqual(
            DeepLink.from(payload: [DeepLink.sessionIDKey: "s1", DeepLink.messageIDKey: "not-a-number"]),
            .session(id: "s1", messageID: nil))
    }

    // MARK: URLs

    func testParsesASessionURL() {
        XCTAssertEqual(DeepLink.from(url: URL(string: "pai://session/abc")!), .session(id: "abc"))
    }

    func testParsesANoteURL() {
        XCTAssertEqual(DeepLink.from(url: URL(string: "pai://note/n1")!), .note(id: "n1"))
    }

    func testParsesANotificationURL() {
        XCTAssertEqual(DeepLink.from(url: URL(string: "pai://notification/n1")!), .notification(id: "n1"))
    }

    /// Some callers build the URL from `URLComponents` with no host, which yields an empty
    /// authority and puts everything in the path.
    func testParsesAURLWithAnEmptyAuthority() {
        XCTAssertEqual(DeepLink.from(url: URL(string: "pai:///note/n1")!), .note(id: "n1"))
    }

    func testRejectsAnotherAppsScheme() {
        XCTAssertNil(DeepLink.from(url: URL(string: "https://note/n1")!))
    }

    /// The case that matters most: our scheme, a shape we do not understand. Guessing here sends
    /// someone to a screen they did not ask for, which is worse than doing nothing.
    func testRejectsAnUnknownHostOnOurOwnScheme() {
        XCTAssertNil(DeepLink.from(url: URL(string: "pai://settings/x")!))
    }

    func testRejectsAHostWithNoId() {
        XCTAssertNil(DeepLink.from(url: URL(string: "pai://note")!))
        XCTAssertNil(DeepLink.from(url: URL(string: "pai://note/")!))
    }

    func testRejectsExtraPathSegments() {
        XCTAssertNil(DeepLink.from(url: URL(string: "pai://note/n1/extra")!))
    }

    /// `notesList` and `createSession` carry no id, so they parse from a bare host — but they must
    /// not swallow a trailing segment nobody asked them to, the same guard `testRejectsExtra
    /// PathSegments` proves for the id-carrying cases.
    func testParsesTheIdLessLinks() {
        XCTAssertEqual(DeepLink.from(url: URL(string: "pai://notes")!), .notesList)
        XCTAssertEqual(DeepLink.from(url: URL(string: "pai://createsession")!), .createSession)
    }

    func testRejectsAnExtraSegmentAfterAnIdLessHost() {
        XCTAssertNil(DeepLink.from(url: URL(string: "pai://notes/extra")!))
        XCTAssertNil(DeepLink.from(url: URL(string: "pai://createsession/extra")!))
    }

    /// A shortcut stores the URL this property produces and hands it back months later, so the
    /// two sides have to agree for ids that are not URL-safe.
    func testAURLRoundTripsThroughParsing() {
        for link in [
            DeepLink.session(id: "a b/c"), .note(id: "n#1"), .note(id: "plain"), .notesList, .createSession,
            .notification(id: "n/1"),
        ] {
            guard let url = link.url else { return XCTFail("\(link) produced no URL") }
            XCTAssertEqual(DeepLink.from(url: url), link, "\(url) did not round-trip")
        }
    }

    // MARK: Routes

    /// A note opened from a shortcut must have the index underneath it — arriving with an empty
    /// back stack strands the reader on one note with no way into the app.
    func testANoteLinkLandsOnTheIndexAndThenTheNote() {
        XCTAssertEqual(DeepLink.note(id: "n1").routes, [.notes, .note(id: "n1")])
    }

    func testNotesListLandsOnTheIndex() {
        XCTAssertEqual(DeepLink.notesList.routes, [.notes])
    }

    func testCreateSessionLandsOnTheCreateSessionRoute() {
        XCTAssertEqual(DeepLink.createSession.routes, [.createSession])
    }

    func testASessionLinkLandsDirectlyOnTheSession() {
        XCTAssertEqual(DeepLink.session(id: "s1").routes, [.session(id: "s1")])
    }

    /// A cold push replaces the whole stack with just the session — never `[.notifications,
    /// .session(...)]`, which is reserved for a tap made from inside the centre itself and never
    /// travels through `DeepLink` at all (see `.notification`'s doc comment).
    func testASessionLinkWithAMessageIDStillLandsDirectlyOnTheSession() {
        XCTAssertEqual(
            DeepLink.session(id: "s1", messageID: 42).routes, [.session(id: "s1", messageID: 42)])
    }

    /// `.routes` cannot resolve a bare notification id to anything more specific than the centre
    /// — see the case's own doc comment for why the real resolution needs a network round trip
    /// and lives in `RootView` instead.
    func testANotificationLinkFallsBackToTheCentre() {
        XCTAssertEqual(DeepLink.notification(id: "n1").routes, [.notifications])
    }
}

/// The inbox exists for one reason: a link can arrive before anything is ready to act on it.
@MainActor
final class DeepLinkInboxTests: XCTestCase {

    func testALinkWaitsUntilItIsConsumed() async {
        let inbox = DeepLinkInbox()
        inbox.receive(.note(id: "n1"))
        XCTAssertEqual(inbox.pending, .note(id: "n1"))
        XCTAssertEqual(inbox.consume(), .note(id: "n1"))
    }

    /// The property this exists to guarantee. A link left pending is re-consumed by the next
    /// observer, which pins the app on one screen — navigating away re-navigates straight back.
    func testConsumingClearsIt() async {
        let inbox = DeepLinkInbox()
        inbox.receive(.session(id: "s1"))
        _ = inbox.consume()
        XCTAssertNil(inbox.pending)
        XCTAssertNil(inbox.consume())
    }

    /// Two taps before the app is ready is one person tapping twice, and they want the second.
    func testASecondLinkReplacesTheFirst() async {
        let inbox = DeepLinkInbox()
        inbox.receive(.note(id: "first"))
        inbox.receive(.note(id: "second"))
        XCTAssertEqual(inbox.consume(), .note(id: "second"))
    }
}
