import Foundation

/// Swift port of `pai-cloud/web/src/api/types.ts` (the "SSE Events" / "Terminal streaming"
/// sections). Payload shapes only — the connection/reconnect/cursor logic that decodes these
/// lives in `PaiSseClient` and `PaiTerminalStreamClient`.

public struct SseInitEvent: Codable, Sendable, Equatable {
    public let entries: [Message]
    public let cursor: Int?
    public let hasMore: Bool
    public let sessionTokens: Int?

    enum CodingKeys: String, CodingKey {
        case entries, cursor
        case hasMore = "has_more"
        case sessionTokens = "session_tokens"
    }

    public init(entries: [Message], cursor: Int?, hasMore: Bool, sessionTokens: Int?) {
        self.entries = entries
        self.cursor = cursor
        self.hasMore = hasMore
        self.sessionTokens = sessionTokens
    }
}

public struct SseBatchEvent: Codable, Sendable, Equatable {
    public let entries: [Message]
    public let sessionTokens: Int?

    enum CodingKeys: String, CodingKey {
        case entries
        case sessionTokens = "session_tokens"
    }

    public init(entries: [Message], sessionTokens: Int?) {
        self.entries = entries
        self.sessionTokens = sessionTokens
    }
}

public struct SseStatusEvent: Codable, Sendable, Equatable {
    public let status: SessionStatus
    public let state: SessionState?
    public let blocker: Blocker?
    /// Outgoing messages not yet delivered.
    public let queued: Int?
    /// Their text, oldest first, so the UI can show what is still waiting.
    public let queuedTexts: [String]?
    /// Why the last delivery attempt failed, if one did.
    public let lastError: String?

    enum CodingKeys: String, CodingKey {
        case status, state, blocker, queued
        case queuedTexts = "queued_texts"
        case lastError = "last_error"
    }

    public init(
        status: SessionStatus,
        state: SessionState?,
        blocker: Blocker?,
        queued: Int?,
        queuedTexts: [String]?,
        lastError: String?
    ) {
        self.status = status
        self.state = state
        self.blocker = blocker
        self.queued = queued
        self.queuedTexts = queuedTexts
        self.lastError = lastError
    }
}

public struct SseProcessingEvent: Codable, Sendable, Equatable {
    public let processing: Bool
    public let elapsed: Double

    public init(processing: Bool, elapsed: Double) {
        self.processing = processing
        self.elapsed = elapsed
    }
}

/// Documented for parity with `types.ts`; the terminal stream itself decodes frames loosely
/// (see `PaiTerminalStreamClient`) rather than through this type, because a malformed or
/// non-JSON frame body is a normal case there, not a decode failure.
public struct TerminalFrameEvent: Codable, Sendable, Equatable {
    public let data: String

    public init(data: String) {
        self.data = data
    }
}
