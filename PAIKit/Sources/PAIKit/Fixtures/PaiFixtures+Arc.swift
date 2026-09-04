import Foundation

/// ARC spec fixtures — the `arc` app's own screen. Shape verified against a real
/// `GET /api/arc/specs/{uuid}/recover` response rather than written from the contract alone (see
/// `PaiFixtures`'s own doc comment on why that distinction matters); the content is a synthetic
/// two-segment story, not any real spec's rows.
extension PaiFixtures {

    /// `GET /api/arc/specs?session=...` — one spec bound to the fixture session.
    public static let arcSpecs = """
        {
          "specs": [
            {
              "uuid": "3f1c9d7a-4b8e-4a2f-9c1d-7e5a2b6f0d31",
              "name": "Demo build",
              "phase": "Build",
              "effort": 2,
              "project_id": null,
              "sessions": ["11111111-1111-1111-1111-111111111111"],
              "overview": "A short-lived demo spec for the screenshot workflow.",
              "created_at": "2026-09-01T09:00:00.000000+00:00",
              "updated_at": "2026-09-03T10:00:00.000000+00:00",
              "row_count": 6
            }
          ]
        }
        """

    /// `GET /api/arc/specs/{uuid}` — the fixture spec's own record, matching `arcSpecs`'s single
    /// item field for field but carrying `row_count` unwrapped rather than nested under `specs`,
    /// the shape the plain-by-id route actually answers with.
    public static let arcSpec = """
        {
          "uuid": "3f1c9d7a-4b8e-4a2f-9c1d-7e5a2b6f0d31",
          "name": "Demo build",
          "phase": "Build",
          "effort": 2,
          "project_id": null,
          "sessions": ["11111111-1111-1111-1111-111111111111"],
          "overview": "A short-lived demo spec for the screenshot workflow.",
          "created_at": "2026-09-01T09:00:00.000000+00:00",
          "updated_at": "2026-09-03T10:00:00.000000+00:00",
          "row_count": 6
        }
        """

    /// `GET /api/arc/specs/{uuid}/recover` — two segments: the first Done and behind a marker,
    /// the second holding five parallel blocks (one of each badge state — working, not-spawned,
    /// accepted, returned, cancelled) and a loose row. Gives `ArcSpecView` a segment wide enough
    /// to show real horizontal scrolling, one of every badge state to render, and (block 9) a
    /// leader-only block to prove it renders like any other rather than as a special case.
    public static let arcRecover = """
        {
          "spec": "3f1c9d7a-4b8e-4a2f-9c1d-7e5a2b6f0d31",
          "name": "Demo build",
          "overview": "A short-lived demo spec for the screenshot workflow.",
          "phase": "Build",
          "active_segment": {
            "index": 1,
            "blocks": [
              {
                "b": 2,
                "leader": 4,
                "i": "Build the thing",
                "s": "I",
                "g": {"type": "aria", "model": "sonnet", "name": "arc-demo"},
                "rows": [5, 8],
                "done": 0,
                "cancelled": 1,
                "total": 2
              },
              {
                "b": 3,
                "leader": 6,
                "i": "Review the thing",
                "s": "P",
                "g": null,
                "rows": [],
                "done": 0,
                "cancelled": 0,
                "total": 0
              },
              {
                "b": 9,
                "leader": 10,
                "i": "Ship the review notes",
                "s": "D",
                "g": {"type": "aria", "model": "opus", "name": "arc-accepted-demo", "returned_at": "2026-09-03T09:00:00.000000+00:00"},
                "rows": [],
                "done": 0,
                "cancelled": 0,
                "total": 0
              },
              {
                "b": 11,
                "leader": 12,
                "i": "Draft the follow-up",
                "s": "I",
                "g": {"type": "fable", "model": "fable", "name": "arc-returned-demo", "returned_at": "2026-09-03T09:30:00.000000+00:00"},
                "rows": [],
                "done": 0,
                "cancelled": 0,
                "total": 0
              },
              {
                "b": 13,
                "leader": 14,
                "i": "Abandoned spike",
                "s": "X",
                "g": {"type": "aria", "model": "haiku", "name": "arc-cancelled-demo"},
                "rows": [],
                "done": 0,
                "cancelled": 0,
                "total": 0
              }
            ],
            "loose": [7],
            "busy_agents": ["arc-demo"]
          },
          "rows": {
            "1": {
              "id": 1, "i": "Set up the demo", "src": "U", "diff": 1, "s": "D", "o": 1.0, "k": "L",
              "b": 1, "g": {"type": "kai"}, "n": {"1": "Nothing to build, just wiring."}, "r": [], "v": null
            },
            "2": {
              "id": 2, "i": "Segment one is done", "src": "U", "diff": 0, "s": null, "o": 2.0, "k": "M",
              "b": null, "g": null, "n": {}, "r": [], "v": "The demo spec exists and has rows."
            },
            "4": {
              "id": 4, "i": "Build the thing", "src": "U", "diff": 2, "s": "I", "o": 3.0, "k": "L",
              "b": 2, "g": {"type": "aria", "model": "sonnet", "name": "arc-demo"},
              "n": {"1": "Some *markdown* notes.\\n\\n- one\\n- two"}, "r": [], "v": null
            },
            "5": {
              "id": 5, "i": "The thing itself", "src": "U", "diff": 1, "s": "P", "o": 3.5, "k": "R",
              "b": 2, "g": null,
              "n": {"1": "| Col A | Col B |\\n| --- | --- |\\n| 1 | 2 |\\n\\nProse after the table."},
              "r": [], "v": null
            },
            "8": {
              "id": 8, "i": "A sub-task that got cancelled", "src": "U", "diff": 0, "s": "X", "o": 3.6, "k": "R",
              "b": 2, "g": null,
              "n": {"1": "```swift\\nlet x = 1\\n```\\n\\nProse after the code block."},
              "r": [], "v": null
            },
            "6": {
              "id": 6, "i": "Review the thing", "src": "U", "diff": 1, "s": "P", "o": 4.0, "k": "L",
              "b": 3, "g": null, "n": {}, "r": [], "v": null
            },
            "7": {
              "id": 7, "i": "A stray note, no block yet", "src": "U", "diff": 0, "s": "P", "o": 3.8, "k": "R",
              "b": null, "g": null, "n": {}, "r": [], "v": null
            },
            "10": {
              "id": 10, "i": "Ship the review notes", "src": "U", "diff": 1, "s": "D", "o": 4.2, "k": "L",
              "b": 9, "g": {"type": "aria", "model": "opus", "name": "arc-accepted-demo", "returned_at": "2026-09-03T09:00:00.000000+00:00"},
              "n": {}, "r": [], "v": null
            },
            "12": {
              "id": 12, "i": "Draft the follow-up", "src": "U", "diff": 1, "s": "I", "o": 4.4, "k": "L",
              "b": 11, "g": {"type": "fable", "model": "fable", "name": "arc-returned-demo", "returned_at": "2026-09-03T09:30:00.000000+00:00"},
              "n": {}, "r": [], "v": null
            },
            "14": {
              "id": 14, "i": "Abandoned spike", "src": "U", "diff": 0, "s": "X", "o": 4.6, "k": "L",
              "b": 13, "g": {"type": "aria", "model": "haiku", "name": "arc-cancelled-demo"},
              "n": {}, "r": [], "v": null
            }
          }
        }
        """
}
