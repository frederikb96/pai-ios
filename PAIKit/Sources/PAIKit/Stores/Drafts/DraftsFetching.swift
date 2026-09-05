import Foundation

/// The three drafts calls `DraftStore` needs, narrowed from `PaiApiClient`'s full surface so a
/// test can fake this without the stub-`URLProtocol` machinery the client itself is tested with.
public protocol DraftsFetching: Sendable {
    func getDrafts() async throws -> [Draft]
    func putDraft(
        key: String, text: String, sessionType: String?, workingDir: String?, model: String?
    ) async throws -> PutDraftResult
    func deleteDraft(key: String) async throws -> PaiDraftDeleteResult
}

extension PaiApiClient: DraftsFetching {}
