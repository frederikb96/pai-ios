import Foundation

/// The notes half of the corpus: an index, one note rich enough to exercise every part of the
/// renderer, its link graph and its revisions, and the containers screen's own list.
///
/// The body is deliberately not a tidy paragraph. Every construct in it is one the note screens
/// get wrong in a different way — a heading the outline has to find, a nested list, a code line far
/// wider than a phone, a table, a wikilink that resolves and an embed that does not — so a
/// screenshot of this one note is a check on all of them at once. The name is deliberately long
/// too, well past what an iPhone-width title row can show on one line, so the same screenshot also
/// exercises truncation.
extension PaiFixtures {

    /// A note whose id every note-scoped fixture route answers under, matching
    /// ``Route/fixtureNoteID`` so a screenshot run can ask for "the note" without discovering one.
    public static let noteID = "6a0b5f2e-9d47-4c1a-8f30-2b7e5c918d64"

    public static let notesIndex = #"""
        {"notes":[
          {"id":"6a0b5f2e-9d47-4c1a-8f30-2b7e5c918d64","name":"Engram: how the memory tree is laid out, what reads it back, and why notes are the part written on purpose","summary":"How the memory tree is laid out, and what reads it.","container_id":"c1","favourite":true,"tags":["pai","memory"],"updated_at_ms":1756598400000,"pending_delete":false},
          {"id":"9f31c2aa-0000-4c1a-8f30-2b7e5c918d11","name":"Wikilink","summary":"The note the sample links to.","container_id":"c1","favourite":false,"tags":["pai"],"updated_at_ms":1756512000000,"pending_delete":false},
          {"id":"3b77de40-1111-4c1a-8f30-2b7e5c918d22","name":"Groceries","summary":null,"container_id":"c1","favourite":false,"tags":["home"],"updated_at_ms":1756425600000,"pending_delete":false}
        ]}
        """#

    public static let noteDetail = #"""
        {
          "id":"6a0b5f2e-9d47-4c1a-8f30-2b7e5c918d64",
          "name":"Engram: how the memory tree is laid out, what reads it back, and why notes are the part written on purpose",
          "summary":"How the memory tree is laid out, and what reads it.",
          "container_id":"c1",
          "favourite":true,
          "tags":["pai","memory"],
          "updated_at_ms":1756598400000,
          "pending_delete":false,
          "frontmatter":"tags:\n  - pai\n  - memory\n",
          "body":"# Engram\n\nEvery session is written down, and the tree below is what reads it back.\n\n## What it holds\n\n- projects, each with phases\n- notes, which are the part written on purpose\n    - and their summaries, which is what semantic search matches on\n- links between them, resolved both ways\n\t- the wire format: [[attachments/spec.pdf]]\n\t- an indented item right after a file stays in the list\n\nSee [[Wikilink]] for the other half, and the [spec](https://example.com/spec) for the wire format.\n\n## Reading it back\n\n```sh\nkubectl -n pai-cloud exec deploy/pai-cloud -- psql -At -c \"select id, name from notes order by updated_at desc limit 20\"\n```\n\nProse after a block still wraps the way prose should.\n\n## What the columns mean\n\n| Field | Meaning |\n|---|---|\n| `rel_path` | where the file sits inside the container |\n| `size_bytes` | what it costs to sync |\n\n![[attachments/diagram.png]]\n\n> A quote, dimmed but still legible.\n",
          "content_hash":"sha256:0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0",
          "created_at":"2026-08-01T09:15:00.123456+00:00",
          "created_at_ms":1754039700000,
          "last_write_source":"ui"
        }
        """#

    public static let noteLinkGraph = #"""
        {
          "outgoing":[
            {"ordinal":0,"syntax":"wikilink","is_embed":false,"raw_target":"Wikilink","path_target":"Wikilink","anchor":null,"alias":null,"kind":"note","target_note_id":"9f31c2aa-0000-4c1a-8f30-2b7e5c918d11","target_note_name":"Wikilink","target_attachment_path":null},
            {"ordinal":1,"syntax":"wikilink","is_embed":true,"raw_target":"attachments/diagram.png","path_target":"attachments/diagram.png","anchor":null,"alias":null,"kind":"attachment","target_note_id":null,"target_note_name":null,"target_attachment_path":"attachments/diagram.png"}
          ],
          "backlinks":[
            {"note_id":"3b77de40-1111-4c1a-8f30-2b7e5c918d22","note_name":"Groceries","count":1}
          ],
          "extraction_skipped":false
        }
        """#

    public static let noteRevisions = #"""
        {"revisions":[
          {"id":"r2","created_at_ms":1756595000000,"source":"ui","content_hash":"sha256:aa","size_bytes":1840},
          {"id":"r1","created_at_ms":1756400000000,"source":"disk","content_hash":"sha256:bb","size_bytes":1620}
        ]}
        """#

    public static let notesConfig = #"""
        {"undo_window_seconds":15}
        """#

    public static let noteContainers = #"""
        {"containers":[
          {"id":"c1","agent_slug":"vm","path":"/home/frederik/pai-notes","name":"PAI","enabled":true,"is_default":true,"state":"active","paused_reason":null,"last_scan_at_ms":1756598000000,"last_error":null,"note_count":159,"breaker":null,"created_at":"2026-07-04T11:02:00.000001+00:00","updated_at":"2026-08-31T01:47:00.000001+00:00","skipped":[],"recent":["Engram","Wikilink"]},
          {"id":"c2","agent_slug":"laptop","path":"/home/frederik/Notes","name":"Zettelkasten","enabled":false,"is_default":false,"state":"paused_missing_path","paused_reason":"the directory is not there on this machine","last_scan_at_ms":1756300000000,"last_error":null,"note_count":2311,"breaker":null,"created_at":"2026-07-04T11:03:00.000001+00:00","updated_at":"2026-08-30T22:10:00.000001+00:00","skipped":null,"recent":null}
        ]}
        """#

    /// The 409 a save of ``noteDetail`` meets when the note was edited elsewhere: a newer hash and
    /// a body that differs from the one the fixture note was opened with.
    public static let noteConflict = #"""
        {
          "current_hash":"sha256:9c8b7a6f5e4d3c2b1a09f8e7d6c5b4a39c8b7a6f5e4d3c2b1a09f8e7d6c5b4a3",
          "updated_at_ms":1756602000000,
          "frontmatter":"tags:\n  - pai\n  - memory\n",
          "body":"# Engram\n\nEdited in the browser while the phone was offline.\n"
        }
        """#

    /// The text a seeded offline edit appends to ``noteDetail``'s body.
    public static let notePendingEditSuffix = "\n\nWritten on the plane, not yet synced.\n"

    /// The text a seeded refused edit appends to ``noteDetail``'s body.
    public static let noteRefusedEditSuffix = "\n\nTyped after the note was deleted elsewhere.\n"

    /// The second index entry as `GET /api/notes/{id}` answers it: a note the notes cache never
    /// seeds, so opening it without a connection shows what an unfetched note looks like, and
    /// opening it with one proves the screen asked for the id it was given.
    public static let wikilinkNoteID = "9f31c2aa-0000-4c1a-8f30-2b7e5c918d11"

    public static let groceriesNoteID = "3b77de40-1111-4c1a-8f30-2b7e5c918d22"

    private static func smallNote(id: String, name: String, summary: String?, tags: [String], body: String) -> String {
        let summaryJson = summary.map { "\"\($0)\"" } ?? "null"
        let tagsJson = tags.map { "\"\($0)\"" }.joined(separator: ",")
        return """
            {
              "id":"\(id)","name":"\(name)","summary":\(summaryJson),"container_id":"c1","favourite":false,
              "tags":[\(tagsJson)],"updated_at_ms":1756512000000,"pending_delete":false,
              "frontmatter":"","body":"\(body)",
              "content_hash":"sha256:\(name.lowercased())","created_at":"2026-08-01T09:15:00.123456+00:00",
              "created_at_ms":1754039700000,"last_write_source":"ui"
            }
            """
    }

    public static let noteDetailWikilink = smallNote(
        id: wikilinkNoteID, name: "Wikilink", summary: "The note the sample links to.", tags: ["pai"],
        body: "# Wikilink\\n\\nThe note the Engram sample links to.\\n")

    public static let noteDetailGroceries = smallNote(
        id: groceriesNoteID, name: "Groceries", summary: nil, tags: ["home"],
        body: "# Groceries\\n\\n- [ ] oat milk\\n- [x] tofu\\n")

    /// What `GET /api/notes/{id}` answers for a note of the corpus, `nil` for any other id: each
    /// note is its own body, so a screen that asks for the wrong id gets visibly the wrong note
    /// instead of the one it expected.
    public static func noteDetail(forId id: String) -> String? {
        switch id {
        case noteID: noteDetail
        case wikilinkNoteID: noteDetailWikilink
        case groceriesNoteID: noteDetailGroceries
        default: nil
        }
    }

    /// The per-note routes under `/api/notes/{id}/…` (`links`, `revisions`). The corpus has these
    /// for the rich note only; the others answer the empty shape.
    public static func noteSubresource(forId id: String, suffix: String) -> String? {
        guard noteDetail(forId: id) != nil else { return nil }
        switch (id == noteID, suffix) {
        case (true, "links"): return noteLinkGraph
        case (true, "revisions"): return noteRevisions
        case (false, "links"): return #"{"outgoing":[],"backlinks":[],"extraction_skipped":false}"#
        case (false, "revisions"): return #"{"revisions":[]}"#
        default: return nil
        }
    }

    /// What `PATCH /api/notes/{id}` answers: the fixture note with the fields the request sent,
    /// under a new hash, so a save in fixture mode reads back as the text that was sent.
    public static func notePatched(id: String, requestBody: Data?) -> Data? {
        guard let detail = noteDetail(forId: id) else { return nil }
        guard var note = (try? JSONSerialization.jsonObject(with: data(detail))) as? [String: Any] else {
            return data(detail)
        }
        let sent = requestBody.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        for key in ["body", "name", "favourite"] where sent[key] != nil { note[key] = sent[key] }
        let body = note["body"] as? String ?? ""
        note["content_hash"] = "sha256:patched-\(body.utf8.count)"
        note["last_write_source"] = sent["source"] as? String ?? "ui"
        note["updated_at_ms"] = 1_756_602_060_000
        return (try? JSONSerialization.data(withJSONObject: note)) ?? data(detail)
    }

    public static let noteAttachments = #"""
        {"attachments":[
          {"rel_path":"attachments/diagram.png","basename":"diagram.png","ext":"png","size_bytes":184320,"mtime_ms":1756500000000,"link_count":1},
          {"rel_path":"attachments/spec.pdf","basename":"spec.pdf","ext":"pdf","size_bytes":911204,"mtime_ms":1756100000000,"link_count":0}
        ]}
        """#
}
