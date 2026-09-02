import Foundation
import XCTest

@testable import PAIKit

/// The note fixtures, decoded into the models the app actually uses.
///
/// A screenshot run is the only thing that ever reads these, and a wrong key there costs a metered
/// macOS run to discover — the screen renders its loading or error state and looks like a bug in
/// the screen. Decoding them here turns that into a free failure with the offending key named.
final class PaiFixturesNotesTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: PaiFixtures.data(json))
    }

    private struct NotesPage: Decodable { let notes: [NoteSummary] }
    private struct ContainersPage: Decodable { let containers: [NoteContainer] }
    private struct RevisionsPage: Decodable { let revisions: [NoteRevisionSummary] }
    private struct AttachmentsPage: Decodable { let attachments: [NoteAttachmentRecord] }

    func testTheIndexDecodesAndTheSampleNoteIsInIt() throws {
        let page = try decode(NotesPage.self, PaiFixtures.notesIndex)
        XCTAssertTrue(page.notes.contains { $0.id == PaiFixtures.noteID })
        XCTAssertFalse(page.notes.flatMap(\.tags).isEmpty, "the tag filter would photograph empty")
    }

    /// The id the routes answer under has to be the one the screenshot workflow asks for, or the
    /// note screen renders a note the index does not contain.
    func testTheFixtureNoteIdIsTheOneTheRouteTableIsAskedFor() {
        XCTAssertEqual(PaiFixtures.noteID, Route.fixtureNoteID)
    }

    func testTheNoteDecodesWithEverythingTheRendererNeeds() throws {
        let note = try decode(NoteDetail.self, PaiFixtures.noteDetail)
        XCTAssertEqual(note.id, PaiFixtures.noteID)
        XCTAssertFalse(note.body.isEmpty)
        XCTAssertNotNil(note.createdAtMs, "the info tab would show a dash")
    }

    /// The body exists to exercise the renderer, so the constructs it is supposed to carry are
    /// worth asserting: a photograph of a note with no code block proves nothing about the one
    /// thing sideways scrolling exists for.
    func testTheNoteBodyCarriesEveryConstructTheScreenshotIsFor() throws {
        let body = try decode(NoteDetail.self, PaiFixtures.noteDetail).body
        XCTAssertTrue(body.contains("\n## "), "no second-level heading for the outline to find")
        XCTAssertTrue(body.contains("\n```sh\n"), "no fenced code block")
        XCTAssertTrue(body.contains("\n|---|---|\n"), "no table")
        XCTAssertTrue(body.contains("[[Wikilink]]"), "no wikilink")
        XCTAssertTrue(body.contains("![[attachments/"), "no attachment embed")
        XCTAssertGreaterThan(parseOutline(body).count, 2, "the outline panel would photograph nearly empty")
    }

    /// The point of the code block: a line no phone is wide enough for. One that fits proves
    /// nothing about whether the block scrolls.
    func testTheCodeBlockHasALineTooWideToFit() throws {
        let body = try decode(NoteDetail.self, PaiFixtures.noteDetail).body
        let longest = body.split(separator: "\n").map(\.count).max() ?? 0
        XCTAssertGreaterThan(longest, 90)
    }

    func testTheConfigFixtureDecodes() throws {
        let config = try decode(NotesConfig.self, PaiFixtures.notesConfig)
        XCTAssertGreaterThan(config.undoWindowSeconds, 0)
    }

    func testTheContainersScreenHasSomethingToShow() throws {
        let page = try decode(ContainersPage.self, PaiFixtures.noteContainers)
        XCTAssertEqual(page.containers.count, 2)
        XCTAssertTrue(page.containers.contains { $0.state != "active" }, "only the healthy state is covered")
    }

    func testTheLinkGraphDecodesBothDirections() throws {
        let graph = try decode(NoteLinkGraph.self, PaiFixtures.noteLinkGraph)
        XCTAssertFalse(graph.outgoing.isEmpty)
        XCTAssertFalse(graph.backlinks.isEmpty)
    }

    func testTheRevisionsAndAttachmentsDecode() throws {
        XCTAssertEqual(try decode(RevisionsPage.self, PaiFixtures.noteRevisions).revisions.count, 2)
        XCTAssertEqual(try decode(AttachmentsPage.self, PaiFixtures.noteAttachments).attachments.count, 2)
    }
}

/// The routing half: a fixture that decodes but is never served is a screen that photographs its
/// error state.
final class PaiFixtureNoteRoutingTests: XCTestCase {

    private func status(_ path: String) -> Int {
        PaiFixtureURLProtocol.route(method: "GET", path: path).status
    }

    func testEveryNoteScreenFindsARoute() {
        for path in [
            "/api/notes",
            "/api/notes/\(PaiFixtures.noteID)",
            "/api/notes/\(PaiFixtures.noteID)/links",
            "/api/notes/\(PaiFixtures.noteID)/revisions",
            "/api/notes/containers",
            "/api/notes/containers/c1/attachments",
        ] {
            XCTAssertEqual(status(path), 200, "no fixture route for \(path)")
        }
    }

    /// The one ordering trap in the table: `containers` is not a note id, and read as one it
    /// serves a note to the containers screen, which then shows nothing.
    func testTheContainersPathIsNotReadAsANoteId() {
        let body = String(
            decoding: PaiFixtureURLProtocol.route(method: "GET", path: "/api/notes/containers").body(), as: UTF8.self)
        XCTAssertTrue(body.contains("\"containers\""))
        XCTAssertFalse(body.contains("\"content_hash\""))
    }
}
