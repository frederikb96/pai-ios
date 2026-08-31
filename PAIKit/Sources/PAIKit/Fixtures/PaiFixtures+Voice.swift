import Foundation

/// Drafts, plan usage, secret presence, a voice token, Claude sign-in state, and recording
/// metadata — `GET /api/drafts`, `/api/usage`, `/api/settings/secrets`, `POST /api/voice/token`,
/// `/api/auth/claude`.
///
/// `SmtpSettings` is deliberately not covered: it configures PAI Cloud's own alert mail, which is
/// not part of any screen the iOS overview lists as in scope (session list, search, chat,
/// composer, voice, settings' theme/expand-preferences, read-only terminal). Adding it would be
/// volume with no screen to exercise it against.
extension PaiFixtures {

    // MARK: - Drafts

    /// `GET /api/drafts` — the `new` draft (carrying the launch choices only it needs) and a
    /// draft on ``sessionReady``, whose text carries the load-bearing `stt-rec: ` prefix that
    /// marks a composer body as having come from speech.
    public static let drafts: String = #"""
        [
          { "key": "new", "text": "Check whether the ", "session_type": "default",
            "working_dir": "/home/frederik/Programming/pai-cloud", "updated_at": "2026-08-29T08:55:12Z" },
          { "key": "305df4d3-1554-4fc3-be04-39a354a9e619",
            "text": "stt-rec: also double check the terminal frame shape against what the backend actually sends",
            "session_type": null, "working_dir": null, "updated_at": "2026-08-29T09:40:02Z" }
        ]
        """#

    // MARK: - Plan usage

    /// `GET /api/usage` — both rolling windows plus a per-model weekly cap, matching Claude
    /// Code's own statusline.
    ///
    /// 🚨 The timestamps carry six fractional digits and a numeric offset because that is what
    /// the pod actually serialises. A fixture written with the tidier `...:00Z` form parses under
    /// a default `ISO8601DateFormatter` while the real payload does not, so the corpus agreed
    /// with the client and both disagreed with the wire — and the reset time was simply absent on
    /// a real device with every check green. A fixture is only worth having if it is the shape
    /// that actually arrives.
    public static let usage: String = #"""
        {
          "five_hour": { "utilization": 42.5, "resets_at": "2026-08-29T14:00:00.506812+00:00" },
          "seven_day": { "utilization": 78.1, "resets_at": "2026-09-01T00:00:00.117403+00:00" },
          "seven_day_models": [
            { "model": "claude-opus-5", "utilization": 91.4, "resets_at": "2026-09-01T00:00:00.117403+00:00" },
            { "model": "claude-sonnet-5", "utilization": 33.0, "resets_at": null }
          ],
          "reported_at": "2026-08-29T09:41:00.884120+00:00"
        }
        """#

    /// `GET /api/usage` — the agent hasn't reported recently, so the pod discards the stale
    /// snapshot. Every field on `Usage` is optional for exactly this case.
    public static let usageEmpty: String = "{}"

    // MARK: - App secrets (presence only — never a value)

    /// `GET /api/settings/smtp` — a configured Alert Mail section, so the settings screen
    /// photographs the form rather than an error line.
    public static let smtpSettings: String = #"""
        {
          "host": "smtp.posteo.de", "port": 587, "security": "starttls",
          "username": "alerts@example.invalid", "from_address": "alerts@example.invalid",
          "recipient": "freddy@example.invalid", "enabled": true,
          "updated_at": "2026-07-02T09:00:00Z"
        }
        """#

    /// `GET /api/settings/secrets` — `elevenlabs` set, `smtp_password` absent entirely
    /// (`SecretStatusMap` is a `Partial<Record<...>>`, so a missing key means "never configured",
    /// distinct from `{"set": false, ...}`).
    public static let secretStatuses: String = #"""
        { "elevenlabs": { "set": true, "updated_at": "2026-07-02T11:00:00Z" } }
        """#

    /// `POST /api/voice/token` — a single-use ElevenLabs token. The value is a fixture string,
    /// not a working credential; nothing here is capable of authenticating to ElevenLabs.
    public static let voiceToken: String = #"""
        { "token": "fixture-voice-token-not-a-real-credential", "expires_in": 45 }
        """#

    // MARK: - Claude sign-in on the VM (`GET /api/auth/claude`)

    public static let claudeAuthHealthy: String = #"""
        {
          "known": true, "logged_in": true, "health": "ok", "rejected_since": null,
          "subscription": "max",
          "access_expires_at": 1798623600000, "refresh_expires_at": 1801611600000,
          "login": null, "last_error": null, "reported_at": "2026-08-29T09:41:00Z"
        }
        """#

    /// `known: false` — the VM has not reported yet. Distinct from "signed out": nothing here
    /// should raise a banner about a state nobody actually observed.
    public static let claudeAuthUnknown: String = #"""
        { "known": false }
        """#

    public static let claudeAuthSignedOut: String = #"""
        {
          "known": true, "logged_in": false, "health": "signed_out", "rejected_since": null,
          "subscription": null,
          "access_expires_at": null, "refresh_expires_at": null,
          "login": null, "last_error": "refresh token rejected: invalid_grant",
          "reported_at": "2026-08-29T09:35:00Z"
        }
        """#

    /// The state that looks healthy from every angle except the one that counts: a credential
    /// file that parses fine, an access token whose own expiry is hours away, a refresh token a
    /// month out — and an account that answers 401 to every request. Shaped from the live
    /// snapshot of the outage that produced it, so nothing here is tidier than the wire.
    public static let claudeAuthRejected: String = #"""
        {
          "known": true, "logged_in": false, "health": "rejected",
          "rejected_since": 1798620000000,
          "subscription": "max",
          "access_expires_at": 1798623600000, "refresh_expires_at": 1801611600000,
          "login": null, "last_error": null, "reported_at": "2026-08-29T09:42:00Z"
        }
        """#

    public static let claudeAuthLoginInProgress: String = #"""
        {
          "known": true, "logged_in": false,
          "login": {
            "id": "20da6f97-8766-4c18-816f-75b5690aca4a",
            "url": "https://claude.ai/oauth/authorize?state=fixture-state&code_challenge=fixture-challenge",
            "state": "awaiting_code",
            "started_at": 1798600000000
          },
          "reported_at": "2026-08-29T09:36:00Z"
        }
        """#

    // MARK: - Recordings ("past recordings" sheet)
    //
    // Not part of the REST contract at all — `RecordingMeta` lives client-side only
    // (`pai-cloud/web/src/stores/settings.ts`), one per browser's localStorage. Field names below
    // mirror that source, since it's still the closest thing to a spec this shape has; a future
    // iOS `RecordingMeta` model is free to diverge, and there is nothing to reconcile against
    // when it does.

    /// A clean recording — 16 kHz Bluetooth headset, wideband, silence-terminated, both the raw
    /// capture and what was actually sent kept (the two rates differ, so both bytes exist).
    public static let recordingClean: String = #"""
        {
          "timestamp": 1798610000000,
          "durationMs": 8420,
          "sampleRate": 16000,
          "rawSampleRate": 16000,
          "mic": {
            "label": "AirPods Pro",
            "trackSampleRate": 16000,
            "contextSampleRate": 48000,
            "channelCount": 1,
            "echoCancellation": true,
            "noiseSuppression": true,
            "autoGainControl": true,
            "userAgent": "fixture-agent/1.0"
          },
          "rawStored": true,
          "endedBy": "silence",
          "silence": { "enabled": true, "threshold": 0.02, "durationMs": 1500, "triggered": true },
          "stt": { "model": "scribe_v2_realtime", "language": "en", "vadSilenceSecs": 1.5, "vadThreshold": 0.4 },
          "transcript": "stt-rec: check whether the terminal frame shape matches what the backend sends",
          "levels": { "peak": 0.71, "rms": 0.18, "clippedSamples": 0 },
          "narrowband": false,
          "startup": { "captureMs": 210, "socketMs": 1780 },
          "mutedMs": 0
        }
        """#

    /// A degraded one — Bluetooth Hands-Free fallback (8 kHz, narrowband), cut short by an
    /// interruption, raw capture dropped under the storage budget. Every field past `durationMs`
    /// is optional for exactly this case: a recording made by an earlier build must still open.
    public static let recordingDegraded: String = #"""
        {
          "timestamp": 1798500000000,
          "durationMs": 2110,
          "sampleRate": 8000,
          "mic": {
            "label": "Car Bluetooth",
            "trackSampleRate": null,
            "contextSampleRate": 8000,
            "channelCount": 1,
            "echoCancellation": null,
            "noiseSuppression": null,
            "autoGainControl": null,
            "userAgent": "fixture-agent/1.0"
          },
          "rawStored": false,
          "endedBy": "interrupted",
          "narrowband": true
        }
        """#

    public static let recordings: String = #"""
        [\#(recordingClean), \#(recordingDegraded)]
        """#
}
