import Observation

/// What each session's composer has picked but not yet sent.
///
/// App-wide rather than held by the composer, for the same reason ``DraftStore`` is: leaving a
/// session and coming back is something people do mid-message — to check another session, to look
/// something up — and a photo picked before that trip is gone by the time they return, with no
/// sign it was ever there. The text already survived; the files did not.
///
/// Local to this device on purpose. A staged file is bytes in memory, not a draft the backend
/// knows about — the web does not sync them either.
@Observable
@MainActor
final class StagedAttachmentStore {
    private var bySession: [String: [StagedAttachment]] = [:]

    func attachments(for sessionID: String) -> [StagedAttachment] {
        bySession[sessionID] ?? []
    }

    func set(_ attachments: [StagedAttachment], for sessionID: String) {
        if attachments.isEmpty {
            bySession[sessionID] = nil
        } else {
            bySession[sessionID] = attachments
        }
    }

    func append(_ attachments: [StagedAttachment], to sessionID: String) {
        set(self.attachments(for: sessionID) + attachments, for: sessionID)
    }

    func remove(id: StagedAttachment.ID, from sessionID: String) {
        set(attachments(for: sessionID).filter { $0.id != id }, for: sessionID)
    }
}
