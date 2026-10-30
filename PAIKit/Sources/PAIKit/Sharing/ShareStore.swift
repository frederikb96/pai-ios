import Foundation
import Observation

/// One file on its way into a draft.
///
/// `prepare` produces the bytes at send time, so a batch of large files is never in memory at
/// once. `id` becomes the draft row's id, which makes a retry of a lost answer the same row.
public struct ShareItem: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let prepare: @Sendable () throws -> PaiFileUpload

    public init(
        id: String = UUID().uuidString.lowercased(), name: String,
        prepare: @escaping @Sendable () throws -> PaiFileUpload
    ) {
        self.id = id
        self.name = name
        self.prepare = prepare
    }
}

/// Where shared files land. Either way they wait on a draft until a message is sent from it.
public enum ShareDestination: Equatable, Sendable {
    case newSession
    case session(id: String, title: String)

    public var draftKey: String {
        switch self {
        case .newSession: return DraftKey.newSession
        case .session(let id, _): return id
        }
    }
}

/// What the share screen needs from the backend.
public protocol ShareBackend: Sendable {
    func sessionsToShareInto(query: String?) async throws -> [Session]
    func addDraftAttachment(key: String, file: PaiFileUpload, id: String) async throws -> DraftAttachment
}

extension PaiApiClient: ShareBackend {
    public func sessionsToShareInto(query: String?) async throws -> [Session] {
        try await getSessions(limit: 50, kind: .listed, q: query).sessions
    }
}

/// Remembers that a send started and has not ended, across processes.
///
/// iOS can end an extension without a word, and then no screen of its own can say so. The next
/// share reads the mark left behind, so a share that died is reported rather than forgotten.
public struct ShareAttemptMark: Sendable {
    public let isSet: @Sendable () -> Bool
    public let set: @Sendable (Bool) -> Void

    public init(isSet: @escaping @Sendable () -> Bool, set: @escaping @Sendable (Bool) -> Void) {
        self.isSet = isSet
        self.set = set
    }
}

/// Everything the share screen shows and does, from the sessions it offers to the last upload.
@Observable
@MainActor
public final class ShareStore {

    public enum Phase: Equatable, Sendable {
        case choosing
        case sending(done: Int, total: Int)
        case sent(ShareDestination)
        /// Some files may be on the draft already. Sending again resumes with the rest.
        case failed(ShareDestination, message: String)
    }

    public private(set) var phase: Phase = .choosing
    public private(set) var sessions: [Session] = []
    public private(set) var sessionsError: String?

    public let items: [ShareItem]
    /// Why some of what was shared is not in `items`, or `nil` when all of it is.
    public let refusal: String?
    /// The previous share was ended by the system partway through its send.
    public let previousAttemptDied: Bool

    private let attemptMark: ShareAttemptMark
    private let backend: any ShareBackend
    private var deliveredIds: Set<String> = []

    public init(items: [ShareItem], refusal: String?, backend: any ShareBackend, attemptMark: ShareAttemptMark) {
        self.items = items
        self.refusal = refusal
        self.backend = backend
        self.attemptMark = attemptMark
        previousAttemptDied = attemptMark.isSet()
        attemptMark.set(false)
    }

    /// A session a draft attachment can reach: the same reach the composer has, so one that takes
    /// no message, one that takes no attachment and a subagent's are all left out.
    public static func acceptsAttachments(_ session: Session) -> Bool {
        if session.status == .deleted || session.parentSessionId != nil { return false }
        guard let kind = session.kind else { return true }
        return !sessionKindsWithoutProcess.contains(kind) && !sessionKindsPodResident.contains(kind)
    }

    /// `query` is typed, so a slower earlier answer must not replace a newer one: the screen
    /// cancels the previous call and a cancelled call changes nothing.
    public func loadSessions(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let found = try await backend.sessionsToShareInto(query: trimmed.isEmpty ? nil : trimmed)
            guard !Task.isCancelled else { return }
            sessions = found.filter(Self.acceptsAttachments)
            sessionsError = nil
        } catch {
            guard !Task.isCancelled else { return }
            sessionsError = Self.message(for: error)
        }
    }

    /// Uploads one file at a time, skipping what an earlier attempt delivered. Stops at the first
    /// failure, since the next file would meet the same network or the same refused credential.
    public func send(to destination: ShareDestination) async {
        switch phase {
        case .choosing, .failed: break
        case .sending, .sent: return
        }
        attemptMark.set(true)
        defer { attemptMark.set(false) }
        for (index, item) in items.enumerated() {
            phase = .sending(done: index, total: items.count)
            guard !deliveredIds.contains(item.id) else { continue }
            do {
                let prepare = item.prepare
                let file = try await Task.detached { try prepare() }.value
                let row = try await backend.addDraftAttachment(key: destination.draftKey, file: file, id: item.id)
                // The server answers 200 with this state when it could not place the file.
                guard row.state != "failed" else {
                    phase = .failed(destination, message: "\(item.name) did not reach the server.")
                    return
                }
                deliveredIds.insert(item.id)
            } catch {
                phase = .failed(destination, message: "\(item.name): \(Self.message(for: error))")
                return
            }
        }
        phase = .sent(destination)
    }

    private static func message(for error: Error) -> String {
        guard let paiError = error as? PaiError else { return error.localizedDescription }
        if paiError.isAuthenticationFailure { return "PAI refused the sign-in. Open the app and sign in again." }
        switch paiError {
        case .detail(let detail, _): return detail
        case .http(let statusCode, let reason): return "The server answered \(statusCode) \(reason)."
        case .transport(let detail), .decoding(let detail): return detail
        }
    }
}
