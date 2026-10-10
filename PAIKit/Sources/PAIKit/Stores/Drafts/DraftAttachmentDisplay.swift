import Foundation

/// The rules a composer follows when it holds two halves of the same set: files this device
/// picked (bytes in hand) and rows the server reports for the same draft (possibly the very same
/// files, possibly another device's).
///
/// Here rather than in the view that renders it, and rather than in the app target's staging
/// store, because both questions below are decided by identity and state alone — nothing about
/// them needs a screen, and neither is worth discovering on a phone.
public enum DraftAttachmentDisplay {

    /// The server's rows minus the ones this device is already drawing itself.
    ///
    /// Without this a file shows twice the moment its own upload lands: once as the local chip
    /// with its thumbnail, once as a remote chip with none. `claimedRemoteIds` is what each local
    /// upload came back with.
    public static func remoteOnly(
        _ attachments: [DraftAttachment], claimedRemoteIds: Set<String>
    ) -> [DraftAttachment] {
        attachments.filter { !claimedRemoteIds.contains($0.id) }
    }

    /// A file this device uploaded onto a draft, as far as the staging store can say.
    public struct StagedUpload: Sendable, Equatable {
        public let id: UUID
        public let remoteId: String
        /// `nil` for one restored from disk, whose upload finished in an earlier launch.
        public let uploadedAt: Date?

        public init(id: UUID, remoteId: String, uploadedAt: Date?) {
            self.id = id
            self.remoteId = remoteId
            self.uploadedAt = uploadedAt
        }
    }

    /// Which of this device's uploads the server no longer lists — a send from another device
    /// claimed the row (or it was removed there), so the local chip is a leftover.
    ///
    /// An upload that landed after `requestedAt` is kept: a response produced before it cannot
    /// know the row, and reading that absence as "gone" would drop a file the user just added.
    public static func vanishedUploads(
        _ staged: [StagedUpload], serverIds: Set<String>, requestedAt: Date
    ) -> [UUID] {
        staged.filter { upload in
            !serverIds.contains(upload.remoteId) && (upload.uploadedAt ?? .distantPast) < requestedAt
        }.map(\.id)
    }
}

extension DraftAttachment {
    /// Whether this row is a file the next send will carry, or one something has already gone
    /// wrong for.
    ///
    /// `unclaimed` means a message has already been sent without it; `failed` means the bytes
    /// never reached the server at all. Both look exactly like a healthy row unless something
    /// asks — which is how a photo stopped arriving for hours with the only symptom being a chip
    /// that would not go away.
    public var needsAttention: Bool {
        state == "unclaimed" || state == "failed"
    }
}
