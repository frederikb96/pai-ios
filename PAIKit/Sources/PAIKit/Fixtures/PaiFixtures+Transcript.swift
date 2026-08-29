import Foundation

/// One session's whole transcript — `GET /api/session/{id}/messages` for ``PaiFixtures/sessionReady``
/// (`305df4d3-1554-4fc3-be04-39a354a9e619`). Every `Message.type`, every system `subtype`, both
/// of the two "permanent legacy row" shapes `messageDisplay.ts` still has to guard against, every
/// tool family in `ToolCallCard`'s icon/expand-key switch, and the markdown edge cases that stress
/// the renderer (a GFM table, a long syntax-highlighted code block, nested lists, a very long bare
/// URL, inline code, a blockquote) all live inside this one transcript rather than scattered
/// across unrelated blobs — a screenshot only ever shows one transcript at a time, so that is the
/// coverage that actually pays for itself.
///
/// Field shapes (`"{label}\n\n{body}"` for `agent_message`/`command`, the `<local-command-*>`
/// wrapper, `isUnparsedCommandXml`, the nine tool-call `input` shapes) are taken from
/// `pai-cloud/web/src/utils/messageDisplay.ts`, not guessed.
extension PaiFixtures {

    /// `GET /api/session/{id}/messages?tail=true` for the session above — 52 rows, ids
    /// 9001...9052 (a private range chosen only to be easy to spot in a debugger, not meaningful
    /// on its own).
    public static let transcript: String = #"""
        [
          { "id": 9001, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "user", "subtype": null,
            "outbox_id": 5001, "timestamp": "2026-08-29T06:12:03Z",
            "content": "Build the canned fixture corpus for the screenshot run.",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T06:12:03Z" },

          { "id": 9002, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "system", "subtype": "context",
            "timestamp": "2026-08-29T06:12:05Z",
            "content": "Context compacted to fit the window before continuing.",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T06:12:05Z" },

          { "id": 9003, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "assistant", "subtype": null,
            "timestamp": "2026-08-29T06:12:11Z", "content": null,
            "thinking": "The fixtures need to cover every message subtype, so start by re-reading the report before writing anything.",
            "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T06:12:11Z" },

          { "id": 9004, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "assistant", "subtype": null,
            "timestamp": "2026-08-29T06:12:20Z", "content": null, "thinking": null,
            "tool_calls": [
              { "id": "toolu_bash_01", "name": "Bash",
                "input": { "command": "grep -rn \"backfill\" web/src/api/types.ts backend/src/pai_cloud/api.py" } }
            ],
            "tool_result": null,
            "hook_summary": { "hook_names": ["PostToolUse:Bash"], "has_errors": false, "errors": [], "prevented_continuation": false },
            "tokens": null, "created_at": "2026-08-29T06:12:20Z" },

          { "id": 9005, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "tool_result", "subtype": null,
            "timestamp": "2026-08-29T06:12:21Z", "content": null, "thinking": null, "tool_calls": null,
            "tool_result": { "tool_use_id": "toolu_bash_01", "tool_name": "Bash",
              "content": "backend/src/pai_cloud/api.py:649:            \"backfill\": conn.backfill_snapshot() if conn is not None else None,\n",
              "is_error": false },
            "hook_summary": null, "tokens": null, "created_at": "2026-08-29T06:12:21Z" },

          { "id": 9006, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "assistant", "subtype": null,
            "timestamp": "2026-08-29T06:13:02Z", "content": null, "thinking": null,
            "tool_calls": [
              { "id": "toolu_read_01", "name": "Read",
                "input": { "file_path": "/home/frederik/Programming/pai-cloud/web/src/api/types.ts", "offset": 140, "limit": 6 } }
            ],
            "tool_result": null, "hook_summary": null, "tokens": null, "created_at": "2026-08-29T06:13:02Z" },

          { "id": 9007, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "tool_result", "subtype": null,
            "timestamp": "2026-08-29T06:13:03Z", "content": null, "thinking": null, "tool_calls": null,
            "tool_result": { "tool_use_id": "toolu_read_01", "tool_name": "Read",
              "content": "   140→export interface Message {\n   141→  id: number;\n   142→  session_id: string;\n   143→  type: 'user' | 'assistant' | 'tool_result' | 'system';\n   144→  subtype: string | null;\n   145→  outbox_id?: number | null;\n",
              "is_error": false },
            "hook_summary": null, "tokens": null, "created_at": "2026-08-29T06:13:03Z" },

          { "id": 9008, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "assistant", "subtype": null,
            "timestamp": "2026-08-29T06:14:00Z", "content": null, "thinking": null,
            "tool_calls": [
              { "id": "toolu_grep_01", "name": "Grep", "input": { "pattern": "RecordingMeta", "path": "web/src", "glob": "*.ts" } }
            ],
            "tool_result": null, "hook_summary": null, "tokens": null, "created_at": "2026-08-29T06:14:00Z" },

          { "id": 9009, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "tool_result", "subtype": null,
            "timestamp": "2026-08-29T06:14:01Z", "content": null, "thinking": null, "tool_calls": null,
            "tool_result": { "tool_use_id": "toolu_grep_01", "tool_name": "Grep",
              "content": "web/src/stores/settings.ts:60:export interface RecordingMeta {", "is_error": false },
            "hook_summary": null, "tokens": null, "created_at": "2026-08-29T06:14:01Z" },

          { "id": 9010, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "assistant", "subtype": null,
            "timestamp": "2026-08-29T06:15:00Z", "content": null, "thinking": null,
            "tool_calls": [
              { "id": "toolu_glob_01", "name": "Glob", "input": { "pattern": "**/*.swift", "path": "PAIKit/Sources/PAIKit/Fixtures" } }
            ],
            "tool_result": null, "hook_summary": null, "tokens": null, "created_at": "2026-08-29T06:15:00Z" },

          { "id": 9011, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "tool_result", "subtype": null,
            "timestamp": "2026-08-29T06:15:01Z", "content": null, "thinking": null, "tool_calls": null,
            "tool_result": { "tool_use_id": "toolu_glob_01", "tool_name": "Glob", "content": "", "is_error": false },
            "hook_summary": null, "tokens": null, "created_at": "2026-08-29T06:15:01Z" },

          { "id": 9012, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "assistant", "subtype": null,
            "timestamp": "2026-08-29T06:20:00Z", "content": null, "thinking": null,
            "tool_calls": [
              { "id": "toolu_edit_01", "name": "Edit",
                "input": { "file_path": "/home/frederik/wt/pai-ios-fixtures/PAIKit/Sources/PAIKit/Fixtures/PaiFixtures.swift",
                           "old_string": "public enum PaiFixtures {}", "new_string": "public enum PaiFixtures {\n    public static func data(_ json: String) -> Data { Data(json.utf8) }\n}" } }
            ],
            "tool_result": null, "hook_summary": null, "tokens": null, "created_at": "2026-08-29T06:20:00Z" },

          { "id": 9013, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "tool_result", "subtype": null,
            "timestamp": "2026-08-29T06:20:01Z", "content": null, "thinking": null, "tool_calls": null,
            "tool_result": { "tool_use_id": "toolu_edit_01", "tool_name": "Edit", "content": "Applied 1 edit to PaiFixtures.swift", "is_error": false },
            "hook_summary": null, "tokens": null, "created_at": "2026-08-29T06:20:01Z" },

          { "id": 9014, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "assistant", "subtype": null,
            "timestamp": "2026-08-29T06:25:00Z", "content": null, "thinking": null,
            "tool_calls": [
              { "id": "toolu_write_01", "name": "Write",
                "input": { "file_path": "/home/frederik/wt/pai-ios-fixtures/PAIKit/Sources/PAIKit/Fixtures/PaiFixtures+Sessions.swift",
                           "content": "import Foundation\n\nextension PaiFixtures {\n    public static let agents: String = \"...\"\n}\n" } }
            ],
            "tool_result": null, "hook_summary": null, "tokens": null, "created_at": "2026-08-29T06:25:00Z" },

          { "id": 9015, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "tool_result", "subtype": null,
            "timestamp": "2026-08-29T06:25:01Z", "content": null, "thinking": null, "tool_calls": null,
            "tool_result": { "tool_use_id": "toolu_write_01", "tool_name": "Write", "content": "File written.", "is_error": false },
            "hook_summary": null, "tokens": null, "created_at": "2026-08-29T06:25:01Z" },

          { "id": 9016, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "assistant", "subtype": null,
            "timestamp": "2026-08-29T06:30:00Z", "content": null, "thinking": null,
            "tool_calls": [
              { "id": "toolu_multiedit_01", "name": "MultiEdit",
                "input": { "file_path": "/home/frederik/wt/pai-ios-fixtures/PAIKit/Sources/PAIKit/Fixtures/PaiFixtures+Sessions.swift",
                           "edits": [
                             { "old_string": "let a = 1", "new_string": "let a = 2" },
                             { "old_string": "let b = 3", "new_string": "let b = 4", "replace_all": false }
                           ] } }
            ],
            "tool_result": null, "hook_summary": null, "tokens": null, "created_at": "2026-08-29T06:30:00Z" },

          { "id": 9017, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "tool_result", "subtype": null,
            "timestamp": "2026-08-29T06:30:01Z", "content": null, "thinking": null, "tool_calls": null,
            "tool_result": { "tool_use_id": "toolu_multiedit_01", "tool_name": "MultiEdit", "content": "Applied 2 edits.", "is_error": false },
            "hook_summary": null, "tokens": null, "created_at": "2026-08-29T06:30:01Z" },

          { "id": 9018, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "assistant", "subtype": null,
            "timestamp": "2026-08-29T06:40:00Z", "content": null, "thinking": null,
            "tool_calls": [
              { "id": "toolu_websearch_01", "name": "WebSearch",
                "input": { "query": "ElevenLabs realtime speech-to-text scribe_v2_realtime supported sample rates" } }
            ],
            "tool_result": null, "hook_summary": null, "tokens": null, "created_at": "2026-08-29T06:40:00Z" },

          { "id": 9019, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "tool_result", "subtype": null,
            "timestamp": "2026-08-29T06:40:03Z", "content": null, "thinking": null, "tool_calls": null,
            "tool_result": { "tool_use_id": "toolu_websearch_01", "tool_name": "WebSearch",
              "content": "1. ElevenLabs docs — Speech to Text API\n2. ElevenLabs docs — Realtime transcription\n3. Changelog — scribe_v2_realtime", "is_error": false },
            "hook_summary": null, "tokens": null, "created_at": "2026-08-29T06:40:03Z" },

          { "id": 9020, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "assistant", "subtype": null,
            "timestamp": "2026-08-29T06:41:00Z", "content": null, "thinking": null,
            "tool_calls": [
              { "id": "toolu_webfetch_01", "name": "WebFetch",
                "input": { "url": "https://elevenlabs.io/docs/speech-to-text", "prompt": "What sample rates does the realtime endpoint accept?" } }
            ],
            "tool_result": null, "hook_summary": null, "tokens": null, "created_at": "2026-08-29T06:41:00Z" },

          { "id": 9021, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "tool_result", "subtype": null,
            "timestamp": "2026-08-29T06:41:04Z", "content": null, "thinking": null, "tool_calls": null,
            "tool_result": { "tool_use_id": "toolu_webfetch_01", "tool_name": "WebFetch",
              "content": "The realtime endpoint accepts pcm_8000 through pcm_48000, as pcm_<rate>.", "is_error": false },
            "hook_summary": null, "tokens": null, "created_at": "2026-08-29T06:41:04Z" },

          { "id": 9022, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "assistant", "subtype": null,
            "timestamp": "2026-08-29T06:45:00Z", "content": null, "thinking": null,
            "tool_calls": [
              { "id": "toolu_task_01", "name": "Task",
                "input": { "description": "Survey pai-cloud web/src", "prompt": "Read web/src top to bottom and report the API surface for iOS.", "subagent_type": "Explore" } }
            ],
            "tool_result": null, "hook_summary": null, "tokens": null, "created_at": "2026-08-29T06:45:00Z" },

          { "id": 9023, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "tool_result", "subtype": null,
            "timestamp": "2026-08-29T07:05:00Z", "content": null, "thinking": null, "tool_calls": null,
            "tool_result": { "tool_use_id": "toolu_task_01", "tool_name": "Task",
              "content": "Survey complete — 19 components, 8 stores, and a client with no auth layer at all (it rides an OAuth2-Proxy cookie).", "is_error": false },
            "hook_summary": null, "tokens": null, "created_at": "2026-08-29T07:05:00Z" },

          { "id": 9024, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "assistant", "subtype": null,
            "timestamp": "2026-08-29T07:06:00Z", "content": null, "thinking": null,
            "tool_calls": [ { "id": "toolu_skill_01", "name": "Skill", "input": { "skill": "unit-tests" } } ],
            "tool_result": null, "hook_summary": null, "tokens": null, "created_at": "2026-08-29T07:06:00Z" },

          { "id": 9025, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "tool_result", "subtype": null,
            "timestamp": "2026-08-29T07:06:01Z", "content": null, "thinking": null, "tool_calls": null,
            "tool_result": { "tool_use_id": "toolu_skill_01", "tool_name": "Skill", "content": "(skill instructions loaded)", "is_error": false },
            "hook_summary": null, "tokens": null, "created_at": "2026-08-29T07:06:01Z" },

          { "id": 9026, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "assistant", "subtype": null,
            "timestamp": "2026-08-29T07:10:00Z", "content": null, "thinking": null,
            "tool_calls": [
              { "id": "toolu_mcp_01", "name": "mcp__github__search_code",
                "input": { "query": "Bundle.module resource lookup local Swift package app target", "repo": "apple/swift-package-manager" } }
            ],
            "tool_result": null,
            "hook_summary": { "hook_names": ["PreToolUse:mcp"], "has_errors": true, "errors": ["blocked by a pre-tool-use policy hook"], "prevented_continuation": true },
            "tokens": null, "created_at": "2026-08-29T07:10:00Z" },

          { "id": 9027, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "tool_result", "subtype": null,
            "timestamp": "2026-08-29T07:10:01Z", "content": null, "thinking": null, "tool_calls": null,
            "tool_result": { "tool_use_id": "toolu_mcp_01", "tool_name": "mcp__github__search_code",
              "content": "GitHub API rate limit exceeded, resets in 42 minutes.", "is_error": true },
            "hook_summary": null, "tokens": null, "created_at": "2026-08-29T07:10:01Z" },

          { "id": 9028, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "assistant", "subtype": null,
            "timestamp": "2026-08-29T07:15:00Z",
            "content": "Here's the cost comparison I found:\n\n| Model | Input | Output | Context |\n|---|---:|---:|---:|\n| Opus 5 (1M) | $15/MTok | $75/MTok | 1M |\n| Sonnet 5 | $3/MTok | $15/MTok | 200K |\n| Haiku 4.5 | $0.80/MTok | $4/MTok | 200K |\n\nSonnet 5 is the default for the review pass.",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T07:15:00Z" },

          { "id": 9029, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "assistant", "subtype": null,
            "timestamp": "2026-08-29T07:20:00Z",
            "content": "The event-framing loop is the part actually worth testing — here's the whole thing:\n\n```swift\nstruct SseEventFramer {\n    private var buffer = \"\"\n\n    mutating func feed(_ chunk: String) -> [SseEvent] {\n        buffer += chunk\n        var events: [SseEvent] = []\n        while let range = buffer.range(of: \"\\n\\n\") {\n            let raw = String(buffer[buffer.startIndex..<range.lowerBound])\n            buffer.removeSubrange(buffer.startIndex..<range.upperBound)\n            if let event = SseEvent(parsing: raw) {\n                events.append(event)\n            }\n        }\n        return events\n    }\n}\n\nstruct SseEvent {\n    let name: String\n    let data: String\n\n    init?(parsing raw: String) {\n        var name = \"message\"\n        var dataLines: [String] = []\n        for line in raw.split(separator: \"\\n\", omittingEmptySubsequences: false) {\n            if line.hasPrefix(\"event:\") {\n                name = line.dropFirst(6).trimmingCharacters(in: .whitespaces)\n            } else if line.hasPrefix(\"data:\") {\n                dataLines.append(String(line.dropFirst(5).trimmingCharacters(in: .whitespaces)))\n            }\n        }\n        guard !dataLines.isEmpty else { return nil }\n        self.name = name\n        self.data = dataLines.joined(separator: \"\\n\")\n    }\n}\n```\n\nLifting this out of `URLSession.bytes(for:)` is what would make it Linux-testable.",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T07:20:00Z" },

          { "id": 9030, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "assistant", "subtype": null,
            "timestamp": "2026-08-29T07:25:00Z",
            "content": "Coverage plan for the fixture corpus:\n\n- Sessions\n  - Both machines\n    - vm\n    - laptop\n  - Every state\n    1. starting\n    2. ready\n    3. blocked\n    4. attention\n    5. closed\n  - A subagent\n  - A blocker carrying options\n- Transcript\n  - Every message type\n  - Every system subtype\n  - Markdown edge cases\n- The unhappy paths\n  - An error body\n  - An empty list\n  - A minimal session",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T07:25:00Z" },

          { "id": 9031, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "assistant", "subtype": null,
            "timestamp": "2026-08-29T07:30:00Z",
            "content": "The export endpoint for the reproduction case is:\n\nhttps://pai.frederikberg.com/api/session/305df4d3-1554-4fc3-be04-39a354a9e619/export?since=2026-08-01T00%3A00%3A00Z&format=json&include_attachments=true&flatten=false&redact_secrets=true&max_bytes=75000000\n\nDon't open that from a device signed out of the tunnel.",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T07:30:00Z" },

          { "id": 9032, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "assistant", "subtype": null,
            "timestamp": "2026-08-29T07:35:00Z",
            "content": "> Green checks here say almost nothing about whether the system works.\n> — pai-cloud's own CLAUDE.md\n\nSo the honest follow-up is to decode these fixtures directly against `Session.self` and `Message.self` once the models settle, with `JSONDecoder().decode(...)` as the real conformance test — not the `JSONSerialization` check this pass uses.",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T07:35:00Z" },

          { "id": 9033, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "assistant", "subtype": null,
            "timestamp": "2026-08-29T07:36:00Z", "content": "", "thinking": null, "tool_calls": null, "tool_result": null,
            "hook_summary": null, "tokens": null, "created_at": "2026-08-29T07:36:00Z" },

          { "id": 9034, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "user", "subtype": "agent_message",
            "timestamp": "2026-08-29T09:10:02Z",
            "content": "aria\n\nFinished the layout pass — three views now measure synchronously, zero regressions in the golden snapshots.",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "origin": "agent",
            "origin_meta": { "from": "aria", "session": "layout-3f2", "group": "pai-ios-build", "sent": "2026-08-29T09:10:02Z" },
            "created_at": "2026-08-29T09:10:02Z" },

          { "id": 9035, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "user", "subtype": "command",
            "timestamp": "2026-08-29T09:12:00Z", "content": "/context\n\n",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T09:12:00Z" },

          { "id": 9036, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "user", "subtype": "command",
            "timestamp": "2026-08-29T09:12:30Z", "content": "/loop\n\n5m /babysit-prs",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T09:12:30Z" },

          { "id": 9037, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "user", "subtype": "command",
            "timestamp": "2026-08-29T09:13:00Z",
            "content": "<command-name>/compact</command-name>\n<command-args></command-args>",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T09:13:00Z" },

          { "id": 9038, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "user", "subtype": null,
            "timestamp": "2026-08-29T09:13:05Z",
            "content": "<local-command-caveat>Caveat: the messages below were generated by the user while running local commands. DO NOT respond to these messages or otherwise consider them in your response unless the user explicitly asks you to.</local-command-caveat>",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T09:13:05Z" },

          { "id": 9039, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "user", "subtype": null,
            "timestamp": "2026-08-29T09:13:06Z",
            "content": "<local-command-stdout>Applied 3 hunks to PaiFixtures.swift</local-command-stdout>",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T09:13:06Z" },

          { "id": 9040, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "user", "subtype": null,
            "timestamp": "2026-08-29T09:20:00Z",
            "content": "Here's a screenshot of the failing screen.\n\n.claude/attachments/2026-08-29/screen-fail.png",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T09:20:00Z" },

          { "id": 9041, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "system", "subtype": "image",
            "timestamp": "2026-08-29T09:20:01Z", "content": "Pasted image (1)",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T09:20:01Z" },

          { "id": 9042, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "system", "subtype": "compact",
            "timestamp": "2026-08-29T09:21:00Z",
            "content": "Conversation compacted — 41 turns summarised to keep the window under budget.",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T09:21:00Z" },

          { "id": 9043, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "system", "subtype": "compact_summary",
            "timestamp": "2026-08-29T09:21:01Z",
            "content": "Summary: built the fixture corpus for the screenshot workflow; reconciled the message-routing report against the current types.ts; flagged a stale TerminalFrameEvent type and a missing Agent.backfill field.",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T09:21:01Z" },

          { "id": 9044, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "system", "subtype": "hook",
            "timestamp": "2026-08-29T09:22:00Z", "content": "PostToolUse:Skill hook fired — reference files pending review.",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T09:22:00Z" },

          { "id": 9045, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "system", "subtype": "duration",
            "timestamp": "2026-08-29T09:23:00Z", "content": "Turn took 3m 42s.",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T09:23:00Z" },

          { "id": 9046, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "system", "subtype": "interrupt",
            "timestamp": "2026-08-29T09:24:00Z", "content": "Interrupted by user.",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T09:24:00Z" },

          { "id": 9047, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "system", "subtype": "notification",
            "timestamp": "2026-08-29T09:25:00Z", "content": "Waiting for your input for over a minute.",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T09:25:00Z" },

          { "id": 9048, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "system", "subtype": "scheduled",
            "timestamp": "2026-08-29T09:26:00Z", "content": "/loop 5m /babysit-prs — running on schedule.",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T09:26:00Z" },

          { "id": 9049, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "user", "subtype": "pai_message",
            "timestamp": "2026-08-29T09:27:00Z", "content": "New message from the laptop session: repository setup finished.",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T09:27:00Z" },

          { "id": 9050, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "system", "subtype": "skill",
            "timestamp": "2026-08-29T09:28:00Z", "content": "Invoked skill: scrolling",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T09:28:00Z" },

          { "id": 9051, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "system", "subtype": "command_output",
            "timestamp": "2026-08-29T09:29:00Z", "content": "Applied 3 hunks to PaiFixtures.swift",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
            "created_at": "2026-08-29T09:29:00Z" },

          { "id": 9052, "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619", "type": "assistant", "subtype": null,
            "timestamp": "2026-08-29T09:41:55Z",
            "content": "Reconciled the fixtures against the live contract — done.",
            "thinking": null, "tool_calls": null, "tool_result": null, "hook_summary": null,
            "tokens": { "input_tokens": 1204, "output_tokens": 312, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 18344,
                        "cache_creation": { "ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 0 } },
            "created_at": "2026-08-29T09:41:55Z" }
        ]
        """#
}
