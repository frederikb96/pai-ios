import Foundation

/// The key under which the not-yet-created session's draft is stored — its text and its launch
/// choices are as much a part of it as an existing session's key is a part of that session.
public enum DraftKey {
    public static let newSession = "new"
}

/// Composer text that has not been sent, plus the launch choices that only mean anything for
/// ``DraftKey/newSession``. Swift port of `pai-cloud/web/src/stores/drafts.ts`'s `DraftEntry`.
public struct DraftEntry: Equatable, Sendable {
    public var text: String
    public var sessionType: String?
    public var workingDir: String?
    /// `updated_at` of the server version this entry was last reconciled with.
    ///
    /// Compared for **inequality, never ordered**, in ``DraftStore/syncFromServer()`` — the
    /// device's clock and the server's do not have to agree for that comparison to be correct.
    public var remoteUpdatedAt: String?

    public init(text: String, sessionType: String?, workingDir: String?, remoteUpdatedAt: String?) {
        self.text = text
        self.sessionType = sessionType
        self.workingDir = workingDir
        self.remoteUpdatedAt = remoteUpdatedAt
    }

    public static let empty = DraftEntry(text: "", sessionType: nil, workingDir: nil, remoteUpdatedAt: nil)
}
