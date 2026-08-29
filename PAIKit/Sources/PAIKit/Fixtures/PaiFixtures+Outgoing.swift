import Foundation

/// Request bodies the app itself sends — cheap to fixture alongside the responses, and the half
/// that actually catches a control which renders correctly and puts the wrong thing on the wire.
/// `postMessage` is the one outgoing call `client.ts` sends as `multipart/form-data` rather than
/// JSON (it also carries files), so it is expressed here as its non-file fields only.
extension PaiFixtures {

    /// `PUT /api/drafts/{key}` body for the `new` draft — text plus the launch choices only that
    /// key carries.
    public static let outgoingPutDraftNew: String = #"""
        { "text": "Check whether the terminal frame fixture matches the live wire shape.",
          "session_type": "default", "working_dir": "/home/frederik/Programming/pai-cloud" }
        """#

    /// `PUT /api/drafts/{key}` body for an existing session's draft — no launch choices.
    public static let outgoingPutDraftSession: String = #"""
        { "text": "stt-rec: also double check the terminal frame shape" }
        """#

    /// The non-file fields of `POST /api/messages` (`multipart/form-data` — `files[]` is not
    /// representable as JSON and is omitted). Omitting `session_id` is what creates a session
    /// from this exact same send.
    public static let outgoingPostMessageNewSession: String = #"""
        { "message": "Build the canned fixture corpus for the screenshot run.",
          "session_type": "default", "working_dir": "/home/frederik/wt/pai-ios-fixtures", "agent": "vm" }
        """#

    public static let outgoingPostMessageExistingSession: String = #"""
        { "message": "Also cover the terminal frame's live:false case.",
          "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619" }
        """#

    /// `PATCH /api/session/{id}` — rename.
    public static let outgoingRenameSession: String = #"""
        { "title": "PAI iOS fixture corpus" }
        """#

    /// `PATCH /api/session/{id}` — lock the title against the auto-summariser.
    public static let outgoingSetTitleLocked: String = #"""
        { "title_locked": true }
        """#

    /// `POST /api/session/{id}/blocker/answer` — answering the choice-prompt blocker in
    /// ``PaiFixtures/sessionBlockedChoice`` with its second option.
    public static let outgoingAnswerBlocker: String = #"""
        { "key": "2" }
        """#

    /// `POST /api/favorites`.
    public static let outgoingAddFavorite: String = #"""
        { "path": "/home/frederik/Programming/pai-ios-fixtures" }
        """#

    /// `POST /api/voice/token`.
    public static let outgoingMintVoiceToken: String = #"""
        { "purpose": "realtime" }
        """#
}
