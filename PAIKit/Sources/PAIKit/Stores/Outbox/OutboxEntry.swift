import Foundation

/// Where a queued send goes: an existing session, or a session that does not exist yet and this
/// entry itself will create. Two shapes rather than an optional `sessionId` plus a bag of launch
/// fields, so a `.session` entry cannot accidentally carry launch choices nothing will read.
public enum OutboxTarget: Codable, Sendable, Equatable {
    case session(sessionId: String)
    case newSession(agent: String?, sessionType: String?, workingDir: String?, model: String?, thinking: String?)

    var sessionId: String? {
        if case let .session(sessionId) = self { return sessionId }
        return nil
    }
    var agent: String? {
        if case let .newSession(agent, _, _, _, _) = self { return agent }
        return nil
    }
    var sessionType: String? {
        if case let .newSession(_, sessionType, _, _, _) = self { return sessionType }
        return nil
    }
    var workingDir: String? {
        if case let .newSession(_, _, workingDir, _, _) = self { return workingDir }
        return nil
    }
    var model: String? {
        if case let .newSession(_, _, _, model, _) = self { return model }
        return nil
    }
    var thinking: String? {
        if case let .newSession(_, _, _, _, thinking) = self { return thinking }
        return nil
    }

    /// One FIFO worker per key — preserves order for one session, and the server's own outbox
    /// preserves it again. Every `.newSession` entry shares one key: a follow-up typed there
    /// before the first has gone creates a second, honest, session — never attaches to the first.
    var workerKey: String {
        switch self {
        case let .session(sessionId): return "session:\(sessionId)"
        case .newSession: return "new"
        }
    }
}

/// One file staged with this send whose bytes never reached the server as a draft attachment —
/// still uploading, or its upload failed — so it travels inline instead. `localId` is what the
/// caller's own staging store already knows this file by; the bytes themselves live in
/// ``OutboxStorage``, never inline in ``OutboxEntry`` itself, so the entry stays small enough to
/// hold many of at once in memory for the UI.
public struct OutboxInlineFile: Codable, Sendable, Equatable {
    public let localId: String
    public let filename: String
    public let mimeType: String

    public init(localId: String, filename: String, mimeType: String) {
        self.localId = localId
        self.filename = filename
        self.mimeType = mimeType
    }
}

public enum OutboxEntryState: String, Codable, Sendable, Equatable {
    case queued
    case sending
    case sent
    case failed
}

/// What actually reached the server for a `.sent` entry — the caller reads this to clear the
/// draft it came from, insert the session it created, and reconcile with the transcript's own
/// `pending_sends`/`outbox_id` machinery, which takes over from here.
public struct OutboxResult: Codable, Sendable, Equatable {
    public let sessionId: String
    public let messageId: Int
    /// The version of the draft this send consumed and cleared server-side — what
    /// `DraftStore.recordVersionAfterSend` records so this device's own next poll is a no-op.
    public let draftVersion: Int?

    public init(sessionId: String, messageId: Int, draftVersion: Int? = nil) {
        self.sessionId = sessionId
        self.messageId = messageId
        self.draftVersion = draftVersion
    }
}

/// One send, persisted before the composer that produced it is ever cleared — the whole point of
/// an outbox: this entry, and the bubble built from it, exist and are correct before any network
/// request has even left, and survive a reload or an app kill exactly as they were.
///
/// `id` is `clientMessageId` itself — the uuid v4 minted the moment Send was pressed and never
/// re-minted for a retry, which is what makes every resend of this entry idempotent server-side.
public struct OutboxEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String { clientMessageId }
    public let clientMessageId: String
    public var target: OutboxTarget
    public var text: String
    /// Ids of attachments already uploaded onto the draft this send is consuming — claimed
    /// explicitly, never "whatever the draft happens to hold" at the moment the request lands.
    public var draftAttachmentIds: [String]
    public var inlineFiles: [OutboxInlineFile]
    /// How this message was produced — `"call"` for one dictated during a Computer call,
    /// `nil` for an ordinary typed or dictated send.
    public var clientMode: String?
    public var state: OutboxEntryState
    public var attempts: Int
    public var lastError: String?
    public var createdAt: Date
    public var result: OutboxResult?

    public init(
        clientMessageId: String = UUID().uuidString, target: OutboxTarget, text: String,
        draftAttachmentIds: [String] = [], inlineFiles: [OutboxInlineFile] = [], clientMode: String? = nil,
        state: OutboxEntryState = .queued, attempts: Int = 0, lastError: String? = nil, createdAt: Date = Date(),
        result: OutboxResult? = nil
    ) {
        self.clientMessageId = clientMessageId
        self.target = target
        self.text = text
        self.draftAttachmentIds = draftAttachmentIds
        self.inlineFiles = inlineFiles
        self.clientMode = clientMode
        self.state = state
        self.attempts = attempts
        self.lastError = lastError
        self.createdAt = createdAt
        self.result = result
    }
}
