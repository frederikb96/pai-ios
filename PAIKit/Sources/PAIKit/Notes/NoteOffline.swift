import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The notes operations that need the server, with what each says when there is no connection.
/// One place for the wording, so the list, the editor and the sheets cannot drift apart.
public enum NoteOnlineOnly: CaseIterable, Sendable {
    case deleteNote
    case createNote
    case addFile
    case changeAttachment
    case fullTextSearch
    case semanticSearch
    case history
    case links
    case summary
    case sharing
    case containers
    case noteUnavailable

    public var message: String {
        switch self {
        case .deleteNote: "Deleting a note needs a connection, because links to it are updated when it goes."
        case .createNote: "Creating a note needs a connection."
        case .addFile: "Adding a file needs a connection."
        case .changeAttachment: "Changing attachments needs a connection."
        case .fullTextSearch: "Full-text search needs a connection. The filter still works offline."
        case .semanticSearch: "Semantic search needs a connection. The filter still works offline."
        case .history: "Previous versions need a connection."
        case .links: "Links need a connection."
        case .summary: "The summary can be edited once you're back online."
        case .sharing: "Sharing needs a connection."
        case .containers: "Containers need a connection."
        case .noteUnavailable:
            "This note isn't available offline. Notes you've opened recently and your favourites are kept on this phone."
        }
    }

    /// An attachment that was never fetched on this phone.
    public static func attachmentUnavailable(_ name: String) -> String {
        "\(name) isn't available offline."
    }
}

/// What a failed notes request means for an edit that is waiting to be saved.
public enum NoteSyncFailure: Equatable, Sendable {
    /// The request did not reach the server: no network, a timeout, a dropped connection.
    case transport
    /// The server is there but could not take it now (5xx, 429, 408). Worth trying again.
    case retryLater
    /// The note is gone from the server.
    case noteGone
    /// The server refused the request itself; sending it again gets the same answer.
    case rejected(String)
    /// The caller stopped waiting (a view went away, a newer pass replaced this one). Says
    /// nothing about the network or the server.
    case cancelled

    /// Anything that is not a `PaiError` and not a cancellation is the transport's own error
    /// (`URLError` above all), the same reading `OutboxStore` gives it: the request never got an
    /// answer.
    public static func classify(_ error: Error) -> NoteSyncFailure {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError, urlError.code == .cancelled { return .cancelled }
        guard let paiError = error as? PaiError else { return .transport }
        switch paiError {
        case .transport:
            return .transport
        case .decoding(let text):
            return .rejected(text)
        case .detail(_, let statusCode), .http(let statusCode, _):
            if statusCode == 404 { return .noteGone }
            if statusCode >= 500 || statusCode == 429 || statusCode == 408 { return .retryLater }
            return .rejected(paiError.userMessage)
        }
    }

    public static func isTransport(_ error: Error) -> Bool {
        classify(error) == .transport
    }

    public static func isCancellation(_ error: Error) -> Bool {
        classify(error) == .cancelled
    }
}

/// What the store tells the app after syncing edits that waited on this phone, to be shown as a
/// toast. `madeOffline` tells an edit made without a connection apart from one typed online that
/// waited because the server answered with an error.
public enum NoteSyncNotice: Equatable, Sendable {
    /// Waiting edits that reached the server with nothing in the way.
    case synced(count: Int, madeOffline: Bool = true)
    /// A waiting edit was written over a version the server had meanwhile; that version is in
    /// the note's history.
    case overwroteNewerVersion(noteId: String, name: String, madeOffline: Bool = true)
    /// A rename made offline was refused (most often: the name is taken); the note keeps its name.
    case renameRefused(noteId: String, attempted: String, reason: String)

    public var message: String {
        switch self {
        case .synced(let count, let madeOffline):
            let edits = count == 1 ? "1 offline edit" : "\(count) offline edits"
            let waiting =
                count == 1
                ? "1 edit that was waiting for the server" : "\(count) edits that were waiting for the server"
            return madeOffline ? "Synced \(edits)" : "Saved \(waiting)"
        case .overwroteNewerVersion(_, let name, let madeOffline):
            let edit = madeOffline ? "Synced your offline edit" : "Saved your waiting edit"
            return "\(edit) of '\(name)' over a newer version. That version is in the note's history."
        case .renameRefused(_, let attempted, let reason):
            return "Could not rename to '\(attempted)': \(reason)"
        }
    }

    /// The note a "Show" action on the toast opens.
    public var noteId: String? {
        switch self {
        case .synced: nil
        case .overwroteNewerVersion(let noteId, _, _), .renameRefused(let noteId, _, _): noteId
        }
    }
}

/// The outcome of the last ``NotesStore/resumeSync()``.
public struct NoteSyncReport: Codable, Equatable, Sendable {
    /// Waiting edits (made offline, or parked by a server error) that reached the server.
    public var replayed = 0
    /// Of those, the ones written over a newer server version.
    public var conflictsResolved = 0
    /// Renames and favourites sent.
    public var fieldsSynced = 0
    /// Still waiting when the pass ended: no connection, or the server kept refusing.
    public var stillPending = 0

    public init() {}
}

/// One entry of ``NotesCacheStatus/pending``.
public struct NotePendingSummary: Codable, Equatable, Sendable {
    public let noteId: String
    /// `body` or `fields`.
    public let kind: String
    /// The save state as the badge shows it, or `queued` for a rename or favourite.
    public let state: String
    public let attempts: Int
}

/// What the notes cache holds and what is waiting to sync — the Settings section's figures and
/// the debug bridge's answer.
public struct NotesCacheStatus: Codable, Equatable, Sendable {
    public let isOffline: Bool
    public let indexCount: Int
    public let indexFetchedAtMs: Int?
    public let indexLoadMs: Double
    public let cachedBodyCount: Int
    public let cachedAttachmentCount: Int
    public let cacheBytes: Int
    public let budgetBytes: Int
    public let pending: [NotePendingSummary]
    public let lastSyncReport: NoteSyncReport?
}

/// Text kept on this phone that will not reach the server by itself: an edit the server refused
/// (most often because the note was deleted elsewhere), or an outbox file this build could not
/// read. The reader copies it somewhere else or discards it; nothing removes it otherwise.
public struct NoteKeptText: Identifiable, Equatable, Sendable {
    public enum Origin: Equatable, Sendable {
        case refusedEdit(noteId: String)
        case unreadable(fileId: String)
    }

    public let origin: Origin
    /// The note's name as this phone last knew it, or a stand-in for a file that no longer says.
    public let title: String
    /// Why the text is here, in the reader's words.
    public let reason: String
    public let text: String

    public var id: String {
        switch origin {
        case .refusedEdit(let noteId): "edit:\(noteId)"
        case .unreadable(let fileId): "unreadable:\(fileId)"
        }
    }

    public init(origin: Origin, title: String, reason: String, text: String) {
        self.origin = origin
        self.title = title
        self.reason = reason
        self.text = text
    }
}
