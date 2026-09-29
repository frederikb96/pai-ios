import Foundation

/// The drafts calls `DraftStore` needs, narrowed from `PaiApiClient`'s full surface so a test can
/// fake this without the stub-`URLProtocol` machinery the client itself is tested with.
///
/// **Unconditional writes, no CAS.** `putDraft`/`deleteDraft` never take a base version and never
/// answer with a conflict — the server always accepts, bumps `version`, and hands it back; the
/// only ordering question left is the client's own `knownVersion` comparison in
/// ``DraftStore/syncFromServer()``.
public protocol DraftsFetching: Sendable {
    func getDrafts() async throws -> [Draft]
    func putDraft(
        key: String, text: String, deviceId: String?, sessionType: String?, workingDir: String?, model: String?,
        thinking: String?
    ) async throws -> DraftWriteResult
    func deleteDraft(key: String) async throws -> DraftWriteResult
    func addDraftAttachment(key: String, file: PaiFileUpload) async throws -> DraftAttachment
    func removeDraftAttachment(key: String, attachmentId: String) async throws
}

extension PaiApiClient: DraftsFetching {}
