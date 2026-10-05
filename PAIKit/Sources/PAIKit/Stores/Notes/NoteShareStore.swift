import Foundation
import Observation

/// The narrow slice of `PaiApiClient` the sharing UI needs.
public protocol NoteShareApiClient: Sendable {
    func getNoteShare(noteId: String) async throws -> NoteShare
    func putNoteShare(noteId: String, kind: NoteShareKind) async throws -> NoteShareLink
    func deleteNoteShare(noteId: String, kind: NoteShareKind) async throws -> NoteShareDeleted
    func publishNoteShareAttachments(noteId: String, relPaths: [String]) async throws -> NoteShareItemResults
    func acceptNoteShareAttachments(noteId: String, blobIds: [String]) async throws -> NoteShareItemResults
    func discardNoteShareAttachments(noteId: String, blobIds: [String]) async throws -> NoteShareItemResults
    func getNoteShareAttachment(noteId: String, blobId: String) async throws -> NoteAttachmentResult
    func getNoteState(noteId: String, clientId: String) async throws -> NoteState
}

extension PaiApiClient: NoteShareApiClient {}

/// One note's sharing: its two links and the queue of attachments waiting on the owner. Swift port
/// of the web's `ShareSection` / `ShareQueues`.
///
/// There is no local copy of the queues. The backend derives them on every `GET .../share`, so each
/// action here ends with a fresh read rather than patching what is held — the only way the lists
/// stay what a visitor's side would also compute.
@MainActor
@Observable
public final class NoteShareStore {
    public let noteId: String
    public private(set) var share: NoteShare?
    public private(set) var isLoading = false
    public private(set) var isBusy = false
    public private(set) var errorMessage: String?

    private let api: NoteShareApiClient
    /// Told whenever the answer to "does this note have any link" is known or changes, so the list's
    /// share mark follows without its own fetch.
    private let onSharedChanged: @MainActor (Bool) -> Void

    public init(
        noteId: String, api: NoteShareApiClient, onSharedChanged: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.noteId = noteId
        self.api = api
        self.onSharedChanged = onSharedChanged
    }

    // MARK: Derived

    public func link(_ kind: NoteShareKind) -> NoteShareLink? { share?.links[kind] }

    public var hasAnyLink: Bool { share?.links.read != nil || share?.links.edit != nil }

    /// Everything waiting on the owner — files to publish and uploads to accept or discard.
    public var pendingCount: Int { (share?.outgoing.count ?? 0) + (share?.incoming.count ?? 0) }

    /// What "Publish all" covers. A file a visitor's edit introduced is excluded — naming a file in
    /// the body is not a reason to expose it, so each of those needs its own tap — and so is one too
    /// large to publish.
    public var publishAllCandidates: [NoteShareOutgoing] {
        (share?.outgoing ?? []).filter { !$0.requestedByVisitor && !$0.tooLarge }
    }

    /// How many outgoing files "Publish all" leaves for a deliberate tap.
    public var heldBackFromPublishAll: Int { (share?.outgoing.count ?? 0) - publishAllCandidates.count }

    /// The line to show before deleting `kind`, or nil when nothing is at stake: only removing the
    /// last link drops the sandbox, and only uploads nobody accepted are lost with it.
    public func deleteWarning(for kind: NoteShareKind) -> String? {
        guard let share, share.links[kind] != nil else { return nil }
        let isLast = NoteShareKind.allCases.filter { share.links[$0] != nil }.count == 1
        let unaccepted = share.incoming.count
        guard isLast, unaccepted > 0 else { return nil }
        let files = unaccepted == 1 ? "1 uploaded file" : "\(unaccepted) uploaded files"
        return "This is the last link. \(files) nobody accepted yet will be discarded with it."
    }

    // MARK: Reading

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        await refresh()
    }

    /// A fresh read. A failed one leaves the held answer in place — a stale queue beats an empty
    /// one that reads as "nothing waiting".
    @discardableResult
    public func refresh() async -> Bool {
        do {
            let fetched = try await api.getNoteShare(noteId: noteId)
            share = fetched
            errorMessage = nil
            onSharedChanged(fetched.links.read != nil || fetched.links.edit != nil)
            return true
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load the sharing state"
            return false
        }
    }

    // MARK: Links

    @discardableResult
    public func createLink(_ kind: NoteShareKind) async -> NoteShareLink? {
        guard !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            let link = try await api.putNoteShare(noteId: noteId, kind: kind)
            await refresh()
            return link
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not create the link"
            return nil
        }
    }

    @discardableResult
    public func deleteLink(_ kind: NoteShareKind) async -> NoteShareDeleted? {
        guard !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await api.deleteNoteShare(noteId: noteId, kind: kind)
            await refresh()
            return result
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not delete the link"
            return nil
        }
    }

    // MARK: Queues

    @discardableResult
    public func publish(_ relPaths: [String]) async -> Bool {
        await batch(relPaths, failure: "Could not publish") {
            try await self.api.publishNoteShareAttachments(noteId: self.noteId, relPaths: $0)
        }
    }

    @discardableResult
    public func publishAll() async -> Bool { await publish(publishAllCandidates.map(\.relPath)) }

    @discardableResult
    public func accept(_ blobIds: [String]) async -> Bool {
        await batch(blobIds, failure: "Could not accept") {
            try await self.api.acceptNoteShareAttachments(noteId: self.noteId, blobIds: $0)
        }
    }

    @discardableResult
    public func acceptAll() async -> Bool { await accept((share?.incoming ?? []).map(\.id)) }

    @discardableResult
    public func discard(_ blobIds: [String]) async -> Bool {
        await batch(blobIds, failure: "Could not discard") {
            try await self.api.discardNoteShareAttachments(noteId: self.noteId, blobIds: $0)
        }
    }

    @discardableResult
    public func discardAll() async -> Bool { await discard((share?.incoming ?? []).map(\.id)) }

    /// The bytes of a sandbox file, for a preview before accepting. Nil when it is gone.
    public func attachmentData(blobId: String) async -> Data? {
        guard case let .ok(data)? = try? await api.getNoteShareAttachment(noteId: noteId, blobId: blobId) else {
            return nil
        }
        return data
    }

    /// Runs one batch call, then re-reads. True only when every item succeeded; a partial failure
    /// names what failed, since a batch answers per item and a silent half-success would leave the
    /// owner believing the rest went through.
    private func batch(
        _ keys: [String], failure: String, _ call: @escaping ([String]) async throws -> NoteShareItemResults
    ) async -> Bool {
        guard !keys.isEmpty, !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let answer = try await call(keys)
            await refresh()
            let failed = answer.results.filter { !$0.ok }
            guard !failed.isEmpty else { return true }
            errorMessage = failure + ": " + failed.map { "\($0.key) — \($0.error ?? "failed")" }.joined(separator: "; ")
            return false
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? failure
            return false
        }
    }
}

/// How many tabs have this note open, for the editor header. One instance per open editor: its
/// `clientId` is what makes a poll every few seconds count as one viewer rather than many.
///
/// Polled only while the note is shared and the editor is on screen — the web idles the same way —
/// so an unshared note costs no requests at all.
@MainActor
@Observable
public final class NotePresenceStore {
    public private(set) var viewers = 0
    public let clientId: String

    private let api: NoteShareApiClient

    public static let pollInterval: Duration = .seconds(5)

    public init(api: NoteShareApiClient, clientId: String = UUID().uuidString.lowercased()) {
        self.api = api
        self.clientId = clientId
    }

    /// One poll. A failed one keeps the last count rather than showing zero viewers.
    public func pollOnce(noteId: String) async {
        guard let state = try? await api.getNoteState(noteId: noteId, clientId: clientId) else { return }
        viewers = state.viewers
    }

    /// Polls until cancelled; `isShared` is read each round so a note shared while the editor is
    /// open starts being counted, and one whose last link is deleted stops. A note that is not
    /// shared shows no count.
    public func run(noteId: String, isShared: @MainActor () -> Bool) async {
        while !Task.isCancelled {
            if isShared() {
                await pollOnce(noteId: noteId)
            } else {
                viewers = 0
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}
