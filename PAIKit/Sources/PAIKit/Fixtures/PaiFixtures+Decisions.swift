import Foundation

extension PaiFixtures {

    /// `GET /api/decisions` — one session with two open decisions, a blocking one with context and
    /// a plain yes/no, so the pin and the Decisions app draw every part of a line.
    public static let openDecisions: String = #"""
        {
          "decisions": [
            {
              "id": "7c1f0c3e-52b1-4b3a-9a60-0c2b6f1d8a01",
              "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619",
              "session_title": "Fixture session",
              "number": 3,
              "title": "Merge the release branch and tag it",
              "context": "The branch is green.\n\n- **Yes** tags `v1.4.0` and uploads the build.\n- **No** leaves it open.",
              "recommendation": "yes",
              "options": ["yes", "no"],
              "blocks": true,
              "state": "open",
              "answer": null,
              "created_at": "2026-09-01T08:15:00.506812+00:00",
              "updated_at": "2026-09-01T08:15:00.506812+00:00",
              "resolved_at": null
            },
            {
              "id": "2d9b64aa-7f3c-4f0e-b0d4-5a8e2c7710b2",
              "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619",
              "session_title": "Fixture session",
              "number": 2,
              "title": "Use the shared cache for the nightly job",
              "context": "",
              "recommendation": "shared",
              "options": ["shared", "per-run"],
              "blocks": false,
              "state": "open",
              "answer": null,
              "created_at": "2026-09-01T07:40:00.117403+00:00",
              "updated_at": "2026-09-01T07:40:00.117403+00:00",
              "resolved_at": null
            }
          ]
        }
        """#
}
