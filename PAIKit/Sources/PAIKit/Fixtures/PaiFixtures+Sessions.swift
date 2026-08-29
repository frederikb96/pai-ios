import Foundation

/// Machines, session types, identity/health, and the session list — `GET /api/agents`,
/// `/api/session-types`, `/api/me`, `/api/health`, `/api/sessions`, `/api/sessions/search`.
extension PaiFixtures {

    // MARK: - Machines

    /// `GET /api/agents` — one online (`vm`) and one offline (`laptop`), so a session-list
    /// filter has something real to filter on and an offline machine to grey out.
    ///
    /// ⚠️ `vm`'s object carries `backfill`, which `types.ts`'s `Agent` interface does not
    /// declare at all — the backend sends it (`api.py`'s `backfill_snapshot()`, keys
    /// `total_files`/`complete_files`/`total_bytes`/`shipped_bytes`/`pending_bytes`) and
    /// `docs/ARCHITECTURE.md` documents it, but the TypeScript type is missing the field. Kept
    /// in on purpose, both because it is what the wire actually carries and to prove a decoder
    /// tolerates an extra key it was never told about; `laptop` omits it (idle → `null` is also
    /// legal, but an absent key exercises the same "unlisted field" gap from the other side).
    public static let agents: String = #"""
        [
          {
            "slug": "vm",
            "display_name": "PAI VM",
            "online": true,
            "last_seen_at": "2026-08-29T09:42:01Z",
            "ingest_enabled": true,
            "backfill": {
              "total_files": 812,
              "complete_files": 809,
              "total_bytes": 411238912,
              "shipped_bytes": 409991040,
              "pending_bytes": 1247872
            },
            "capabilities": { "fast_sessions": true, "reboot": true, "shell": true },
            "session_types": [
              { "id": "default", "name": "Default", "icon": "terminal" },
              { "id": "fast", "name": "Fast", "icon": "bolt", "working_dir": "/home/frederik/Programming" }
            ]
          },
          {
            "slug": "laptop",
            "display_name": "Freddy's Laptop",
            "online": false,
            "last_seen_at": "2026-08-29T02:03:44Z",
            "ingest_enabled": true,
            "capabilities": { "fast_sessions": false, "reboot": false, "shell": false },
            "session_types": [
              { "id": "default", "name": "Default", "icon": "terminal" }
            ]
          }
        ]
        """#

    // MARK: - Session types (global, unscoped — `GET /api/session-types`)

    public static let sessionTypes: String = #"""
        [
          { "id": "default", "name": "Default", "icon": "terminal" },
          { "id": "fast", "name": "Fast (sandboxed)", "icon": "bolt" },
          { "id": "research", "name": "Research", "icon": "magnifying-glass", "working_dir": "/home/frederik/Programming" }
        ]
        """#

    // MARK: - Identity and health

    /// `GET /api/me`. `identity` is a synthetic value, not Freddy's real one — nothing about
    /// this corpus should be able to leak a real address into a screenshot or a committed file.
    public static let me: String = #"""
        { "identity": "owner@pai.local", "role": "owner", "allowed_session_ids": ["305df4d3-1554-4fc3-be04-39a354a9e619"] }
        """#

    /// `GET /api/health` — everything connected.
    public static let healthOk: String = #"""
        { "status": "ok", "database": "connected", "agent": "connected", "credential": "ok", "timestamp": "2026-08-29T09:42:10Z" }
        """#

    /// `GET /api/health` — the agent has dropped and the VM's Claude credential is signed out.
    /// `status` stays independent of `credential`, per `HealthResponse`'s own doc comment.
    public static let healthDegraded: String = #"""
        { "status": "unavailable", "database": "connected", "agent": "disconnected", "credential": "signed_out", "timestamp": "2026-08-29T09:44:55Z" }
        """#

    // MARK: - Sessions

    /// `starting` on `vm` — launched, not yet registered with Remote Control. No `state` other
    /// than that; `working` is `null` because a session this young hasn't reported it.
    public static let sessionStarting: String = #"""
        {
          "id": "4376dc8c-e136-437f-88e5-16274acd25d8",
          "session_type": "default",
          "status": "pending",
          "state": "starting",
          "blocker": null,
          "working": null,
          "title": null,
          "initial_message": "Set up the new ingest job for the overview sweep.",
          "session_tokens": 0,
          "claude_session_id": null,
          "idle_timeout_minutes": null,
          "effective_idle_timeout_minutes": 480,
          "cse_id": null,
          "created_at": "2026-08-29T07:58:10Z",
          "updated_at": "2026-08-29T07:58:10Z",
          "last_activity_at": "2026-08-29T07:58:10Z",
          "working_dir": "/home/frederik/Programming/pai-cloud",
          "agent": "vm",
          "kind": "conversation",
          "remote_control": false,
          "discovered": false,
          "project_id": null,
          "phase_id": null,
          "project_name": null
        }
        """#

    /// `ready` on `vm`, `working: true` — the transcript in `PaiFixtures+Transcript.swift`
    /// belongs to this session. Every field the interface declares is present at least once
    /// here, since it is the one row a screenshot is most likely to open.
    public static let sessionReady: String = #"""
        {
          "id": "305df4d3-1554-4fc3-be04-39a354a9e619",
          "session_type": "default",
          "status": "active",
          "state": "ready",
          "blocker": null,
          "working": true,
          "title": "PAI iOS fixtures",
          "title_locked": true,
          "initial_message": "Build the canned fixture corpus for the screenshot run.",
          "pending_message": null,
          "session_tokens": 84213,
          "claude_session_id": "20da6f97-8766-4c18-816f-75b5690aca4a",
          "idle_timeout_minutes": null,
          "effective_idle_timeout_minutes": 480,
          "cse_id": "cse_ddf94be720b8",
          "created_at": "2026-08-29T06:12:03Z",
          "updated_at": "2026-08-29T09:41:55Z",
          "last_activity_at": "2026-08-29T09:41:55Z",
          "working_dir": "/home/frederik/wt/pai-ios-fixtures",
          "agent": "vm",
          "kind": "conversation",
          "remote_control": true,
          "discovered": false,
          "project_id": "2b5a5769-a83c-4542-adf1-6ce737d9fc79",
          "phase_id": "e60ab7f0-8a07-4928-a07c-3cbb175a7de0",
          "project_name": "PAIiOS"
        }
        """#

    /// `blocked` on `vm`, a numbered menu with three options — the blocker case the app has to
    /// let Freddy answer without opening the terminal. `pending_message` shows a reply typed
    /// while still blocked, queued rather than sent.
    public static let sessionBlockedChoice: String = #"""
        {
          "id": "aed4e04d-5a7c-48ee-b3a0-2805ce4e08cc",
          "session_type": "default",
          "status": "active",
          "state": "blocked",
          "blocker": {
            "kind": "choice_prompt",
            "question": "Which branch strategy should I use?",
            "options": [
              { "key": "1", "label": "Cherry-pick onto main" },
              { "key": "2", "label": "Rebase the whole branch" },
              { "key": "3", "label": "Open a fresh PR instead" }
            ]
          },
          "working": false,
          "title": "Renovate cleanup",
          "title_locked": false,
          "initial_message": "Clear the backlog of Renovate PRs on kubernetes-hetzner-talos.",
          "pending_message": "Also check whether option 3 needs a fresh branch off current main.",
          "session_tokens": 51902,
          "claude_session_id": "0067e3fb-5fac-430d-8608-fe605ef301cb",
          "idle_timeout_minutes": 240,
          "effective_idle_timeout_minutes": 240,
          "cse_id": "cse_5562f21bca7b",
          "created_at": "2026-08-28T18:03:00Z",
          "updated_at": "2026-08-29T08:50:12Z",
          "last_activity_at": "2026-08-29T08:50:12Z",
          "working_dir": "/home/frederik/Programming/kubernetes-hetzner-talos",
          "agent": "vm",
          "kind": "conversation",
          "remote_control": true,
          "discovered": false,
          "project_id": null,
          "phase_id": null,
          "project_name": null
        }
        """#

    /// `blocked` on `vm` — `trust_prompt`, unconfirmed. Distinct from
    /// ``sessionBlockedTrustConfirmed`` below: this is the raw prompt with its own options,
    /// before (or in place of) the agent's automatic "yes".
    public static let sessionBlockedTrust: String = #"""
        {
          "id": "cc981b21-34d7-47d2-95dc-37d752e305c2",
          "session_type": "default",
          "status": "active",
          "state": "blocked",
          "blocker": {
            "kind": "trust_prompt",
            "question": "Do you trust the files in this folder?",
            "options": [
              { "key": "1", "label": "Yes, proceed" },
              { "key": "2", "label": "No, exit" }
            ]
          },
          "working": false,
          "title": null,
          "initial_message": "Look at what's in ~/Downloads/client-export and summarise it.",
          "session_tokens": 640,
          "claude_session_id": "5897fb69-6d64-4b89-af1e-3a95d3a2c2bd",
          "created_at": "2026-08-29T09:39:40Z",
          "updated_at": "2026-08-29T09:39:44Z",
          "last_activity_at": "2026-08-29T09:39:44Z",
          "working_dir": "/home/frederik/Downloads/client-export",
          "agent": "vm",
          "kind": "conversation",
          "remote_control": true,
          "discovered": false
        }
        """#

    /// `blocked` on `vm` — `trust_prompt_confirmed`: the agent already answered "yes" itself and
    /// is re-polling to confirm the prompt cleared, so the UI says calmly that it handled this
    /// rather than doing it invisibly. No options — nothing left for a person to press.
    public static let sessionBlockedTrustConfirmed: String = #"""
        {
          "id": "386e25af-3eb6-4429-b099-eb05babd227c",
          "session_type": "default",
          "status": "active",
          "state": "blocked",
          "blocker": {
            "kind": "trust_prompt_confirmed",
            "question": "Trusting /home/frederik/Programming/scratch — handled automatically.",
            "options": []
          },
          "working": false,
          "title": "Scratch cleanup",
          "initial_message": "Clear out anything in scratch older than a month.",
          "session_tokens": 1180,
          "claude_session_id": "c00776fa-ff53-4aeb-96a6-de9c14c1557f",
          "created_at": "2026-08-29T09:20:00Z",
          "updated_at": "2026-08-29T09:20:03Z",
          "last_activity_at": "2026-08-29T09:20:03Z",
          "working_dir": "/home/frederik/Programming/scratch",
          "agent": "vm",
          "kind": "conversation",
          "remote_control": true,
          "discovered": false
        }
        """#

    /// `blocked` on `vm` — `login_required`. Carries no options by design: pressing a key
    /// mid-sign-in would race the account-level Claude auth flow, so the UI only says what the
    /// session is waiting for.
    public static let sessionBlockedLogin: String = #"""
        {
          "id": "e5940eb1-6e86-4aeb-b2bd-96843f709c58",
          "session_type": "default",
          "status": "active",
          "state": "blocked",
          "blocker": {
            "kind": "login_required",
            "question": "Waiting for Claude sign-in to finish on the VM.",
            "options": []
          },
          "working": null,
          "title": null,
          "initial_message": "Rebase the pai-cloud PR onto current main.",
          "session_tokens": 0,
          "claude_session_id": "b8842903-1e68-4c57-b48d-f6f57ade3ee2",
          "created_at": "2026-08-29T09:36:00Z",
          "updated_at": "2026-08-29T09:36:01Z",
          "last_activity_at": "2026-08-29T09:36:01Z",
          "working_dir": "/home/frederik/Programming/pai-cloud",
          "agent": "vm",
          "kind": "conversation",
          "remote_control": false,
          "discovered": false
        }
        """#

    /// `blocked` on `vm` — `permission_prompt`: a tool call is waiting on a yes/no it wasn't
    /// pre-authorised for, distinct from `choice_prompt`'s numbered menu.
    public static let sessionBlockedPermission: String = #"""
        {
          "id": "97db9774-333d-466e-999a-c6546dd5fb01",
          "session_type": "default",
          "status": "active",
          "state": "blocked",
          "blocker": {
            "kind": "permission_prompt",
            "question": "Allow Bash to run \"rm -rf node_modules && npm install\"?",
            "options": [
              { "key": "1", "label": "Yes" },
              { "key": "2", "label": "Yes, and don't ask again for Bash" },
              { "key": "3", "label": "No" }
            ]
          },
          "working": false,
          "title": "Dependency refresh",
          "initial_message": "Clear out node_modules and reinstall from a clean lockfile.",
          "session_tokens": 3210,
          "claude_session_id": "4e81b046-8fd8-4e9e-ac1a-775c89878418",
          "created_at": "2026-08-29T09:30:00Z",
          "updated_at": "2026-08-29T09:30:40Z",
          "last_activity_at": "2026-08-29T09:30:40Z",
          "working_dir": "/home/frederik/Programming/pai-cloud/web",
          "agent": "vm",
          "kind": "conversation",
          "remote_control": true,
          "discovered": false
        }
        """#

    /// `attention` on `vm` — an unrecognised prompt on the pane. Red, and the repair is "open
    /// the terminal", not a button.
    public static let sessionAttentionUnknown: String = #"""
        {
          "id": "5aeedf95-2924-426a-91c3-eadc45da6f40",
          "session_type": "default",
          "status": "active",
          "state": "attention",
          "blocker": {
            "kind": "unknown",
            "question": "I need a bit more direction before I continue — see the terminal.",
            "options": []
          },
          "working": null,
          "title": "Migration script",
          "initial_message": "Write a one-off script to repair the overview_tiers backlog.",
          "session_tokens": 22890,
          "claude_session_id": "51b0217b-d654-40ed-a14a-348dfdcd4fdb",
          "created_at": "2026-08-29T07:10:00Z",
          "updated_at": "2026-08-29T09:15:40Z",
          "last_activity_at": "2026-08-29T09:15:40Z",
          "working_dir": "/home/frederik/Programming/pai-cloud/backend",
          "agent": "vm",
          "kind": "conversation",
          "remote_control": true,
          "discovered": false
        }
        """#

    /// `attention` on `vm` — `not_registered`: no `cse_id` at all, so nothing typed into the
    /// pane changes anything and the only repair is stopping and relaunching.
    public static let sessionAttentionNotRegistered: String = #"""
        {
          "id": "fe537ef5-0496-4c28-acc0-be24474d05cd",
          "session_type": "fast",
          "status": "active",
          "state": "attention",
          "blocker": {
            "kind": "not_registered",
            "question": "This session never registered with Remote Control — restart it to recover.",
            "options": []
          },
          "working": null,
          "title": null,
          "initial_message": "Quick check: is the CNPG service name pai-cloud-db-rw or pai-cloud-rw?",
          "session_tokens": 0,
          "claude_session_id": null,
          "cse_id": null,
          "created_at": "2026-08-29T09:33:00Z",
          "updated_at": "2026-08-29T09:33:20Z",
          "last_activity_at": "2026-08-29T09:33:20Z",
          "working_dir": "/home/frederik/Programming",
          "agent": "vm",
          "kind": "conversation",
          "remote_control": false,
          "discovered": false
        }
        """#

    /// `closed` on `vm` — no live process. `working` is entirely absent here, not `null`,
    /// modelling a payload from a backend old enough to predate the field.
    public static let sessionClosed: String = #"""
        {
          "id": "d3922ef1-a6dd-44f2-a238-29e874358ebf",
          "session_type": "default",
          "status": "completed",
          "state": "closed",
          "blocker": null,
          "title": "Renovate — August sweep",
          "title_locked": true,
          "initial_message": "Merge the safe Renovate PRs across the cluster repos.",
          "session_tokens": 133410,
          "claude_session_id": "e60ab7f0-8a07-4928-a07c-3cbb175a7de0",
          "idle_timeout_minutes": 0,
          "effective_idle_timeout_minutes": null,
          "cse_id": "cse_2b5a5769a83c",
          "created_at": "2026-08-24T09:00:00Z",
          "updated_at": "2026-08-24T15:22:47Z",
          "last_activity_at": "2026-08-24T15:22:47Z",
          "working_dir": "/home/frederik/Programming/kubernetes-hetzner-talos",
          "agent": "vm",
          "kind": "conversation",
          "remote_control": true,
          "discovered": false,
          "project_id": null,
          "phase_id": null,
          "project_name": null
        }
        """#

    /// `ready` on `laptop` — idle (`working: false`), proving the second machine is a first-class
    /// citizen rather than a VM-only afterthought.
    public static let sessionLaptopReady: String = #"""
        {
          "id": "ce5b1c4d-5d42-491e-bfa5-1209bdef55ba",
          "session_type": "default",
          "status": "active",
          "state": "ready",
          "blocker": null,
          "working": false,
          "title": "Dotfiles cleanup",
          "initial_message": "Tidy up the zsh aliases that duplicate what scripts/ already provides.",
          "session_tokens": 9120,
          "claude_session_id": "20da6f97-8766-4c18-816f-75b5690aca4a-lt",
          "cse_id": "cse_51b0217bd654",
          "created_at": "2026-08-29T08:00:00Z",
          "updated_at": "2026-08-29T08:41:02Z",
          "last_activity_at": "2026-08-29T08:41:02Z",
          "working_dir": "/home/frederik/dotfiles",
          "agent": "laptop",
          "kind": "conversation",
          "remote_control": true,
          "discovered": false
        }
        """#

    /// `starting` on `laptop`.
    public static let sessionLaptopStarting: String = #"""
        {
          "id": "1776291e-db8d-46c2-bcb9-73c38991779f",
          "session_type": "default",
          "status": "pending",
          "state": "starting",
          "blocker": null,
          "working": null,
          "title": null,
          "initial_message": "Check whether the laptop's SentinelOne agent is up to date.",
          "session_tokens": 0,
          "claude_session_id": null,
          "created_at": "2026-08-29T09:41:00Z",
          "updated_at": "2026-08-29T09:41:00Z",
          "last_activity_at": "2026-08-29T09:41:00Z",
          "working_dir": "/home/frederik",
          "agent": "laptop",
          "kind": "conversation",
          "remote_control": false,
          "discovered": false
        }
        """#

    /// A `subagent` spawned by ``sessionReady`` — never shown as its own top-level row, but
    /// exercised here so a session-detail or group-chat surface has one to render.
    /// `subagent_name` is `null` (a plain Task subagent, not an in-process teammate with a
    /// chosen name); `claude_session_id` is `null` too, since a subagent has no conversation
    /// of its own to resume.
    public static let sessionSubagent: String = #"""
        {
          "id": "eb516249-128b-48cd-894c-7afdacc5643c",
          "session_type": "default",
          "status": "active",
          "state": "ready",
          "blocker": null,
          "working": true,
          "title": null,
          "initial_message": "Read web/src and report the API surface for iOS.",
          "session_tokens": 18042,
          "claude_session_id": null,
          "created_at": "2026-08-29T09:20:00Z",
          "updated_at": "2026-08-29T09:38:00Z",
          "last_activity_at": "2026-08-29T09:38:00Z",
          "working_dir": "/home/frederik/wt/pai-ios-fixtures",
          "agent": "vm",
          "kind": "subagent",
          "parent_session_id": "305df4d3-1554-4fc3-be04-39a354a9e619",
          "subagent_name": null,
          "subagent_type": "Explore",
          "subagent_description": "Survey pai-cloud web/src for the port inventory",
          "remote_control": false,
          "discovered": false
        }
        """#

    /// The "unhappy" session in this file: a **discovered** row PAI never launched, found by the
    /// transcript watcher, written before its first agent round-trip — `state`/`blocker` absent
    /// entirely (not `null`; genuinely missing keys), `title`/`initial_message` still `null`, and
    /// only the non-optional fields present. `discovered && remote_control` both `true` is the
    /// combination `docs/ARCHITECTURE.md` calls out as needing a confirm step before resuming,
    /// since the terminal that registered it may still be open.
    public static let sessionMinimalDiscovered: String = #"""
        {
          "id": "8d2af84c-5469-44b2-9e8b-25000832a9e2",
          "session_type": "default",
          "status": "pending",
          "title": null,
          "initial_message": null,
          "session_tokens": 0,
          "created_at": "2026-08-29T05:00:00Z",
          "updated_at": "2026-08-29T05:00:00Z",
          "last_activity_at": "2026-08-29T05:00:00Z",
          "working_dir": null,
          "discovered": true,
          "remote_control": true
        }
        """#

    /// `GET /api/sessions` — everything above as one page. `nextCursor` is not part of this body
    /// (the real endpoint returns it as the `X-Next-Cursor` response header, per `client.ts`);
    /// a fixture-mode client should treat this page as the last one.
    public static let sessions: String = #"""
        [
        \#(sessionStarting),
        \#(sessionReady),
        \#(sessionBlockedChoice),
        \#(sessionBlockedTrust),
        \#(sessionBlockedTrustConfirmed),
        \#(sessionBlockedLogin),
        \#(sessionBlockedPermission),
        \#(sessionAttentionUnknown),
        \#(sessionAttentionNotRegistered),
        \#(sessionClosed),
        \#(sessionLaptopReady),
        \#(sessionLaptopStarting),
        \#(sessionSubagent),
        \#(sessionMinimalDiscovered)
        ]
        """#

    // MARK: - Search

    /// `GET /api/sessions/search` — one fuzzy hit (`score: null`, per the interface's own doc
    /// comment: a fuzzy rank isn't a comparable scale) and one semantic hit (`score` a cosine
    /// similarity in 0...1).
    public static let sessionSearchResults: String = #"""
        [
          {
            "id": "305df4d3-1554-4fc3-be04-39a354a9e619",
            "session_type": "default",
            "status": "active",
            "state": "ready",
            "title": "PAI iOS fixtures",
            "initial_message": "Build the canned fixture corpus for the screenshot run.",
            "session_tokens": 84213,
            "created_at": "2026-08-29T06:12:03Z",
            "updated_at": "2026-08-29T09:41:55Z",
            "last_activity_at": "2026-08-29T09:41:55Z",
            "working_dir": "/home/frederik/wt/pai-ios-fixtures",
            "agent": "vm",
            "score": null
          },
          {
            "id": "aed4e04d-5a7c-48ee-b3a0-2805ce4e08cc",
            "session_type": "default",
            "status": "active",
            "state": "blocked",
            "title": "Renovate cleanup",
            "initial_message": "Clear the backlog of Renovate PRs on kubernetes-hetzner-talos.",
            "session_tokens": 51902,
            "created_at": "2026-08-28T18:03:00Z",
            "updated_at": "2026-08-29T08:50:12Z",
            "last_activity_at": "2026-08-29T08:50:12Z",
            "working_dir": "/home/frederik/Programming/kubernetes-hetzner-talos",
            "agent": "vm",
            "score": 0.71
          }
        ]
        """#

    // MARK: - Directory browsing (create-session picker → Custom)

    public static let browseResult: String = #"""
        {
          "path": "/home/frederik/Programming",
          "directories": ["pai-cloud", "pai-ios", "scripts", "dotfiles"],
          "roots": ["/home/frederik", "/home/frederik/Programming"]
        }
        """#

    public static let folderFavorites: String = #"""
        [
          { "path": "/home/frederik/Programming/pai-cloud", "created_at": "2026-06-01T10:00:00Z" },
          { "path": "/home/frederik/wt/pai-ios-fixtures", "created_at": "2026-08-20T09:00:00Z" }
        ]
        """#
}
