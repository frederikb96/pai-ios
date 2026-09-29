import Foundation

/// The key under which the not-yet-created session's draft is stored — its text and its launch
/// choices are as much a part of it as an existing session's key is a part of that session.
public enum DraftKey {
    public static let newSession = "new"
}

/// Composer text that has not been sent, plus the launch choices that only mean anything for
/// ``DraftKey/newSession``. Swift port of `pai-cloud/web/src/stores/drafts.ts`'s `DraftEntry`.
///
/// `Codable` for `DraftStore`'s own local persistence, not for the wire — nothing here decodes a
/// server response into this type directly, so there is no shape to keep in step with `Draft`'s
/// own `CodingKeys` and no reason to give this one any.
public struct DraftEntry: Equatable, Sendable, Codable {
    /// The device owns this text — nothing coming from the network may replace it, and nothing
    /// composes it from anything else. A live dictation take writes here too, through the
    /// ordinary setter, exactly like typing.
    public var text: String
    public var sessionType: String?
    public var workingDir: String?
    /// A `claude --model` alias for the next session — only meaningful on ``DraftKey/newSession``,
    /// alongside `sessionType`/`workingDir`. `nil` lets Claude Code pick the plan's own default.
    public var model: String?
    /// A `claude --effort` level for the next session — only meaningful alongside `model` above.
    /// `nil` lets Claude Code pick the plan's own default.
    public var thinking: String?
    /// `version` of the server row this entry was last reconciled with — `nil` for a key never
    /// yet written or adopted. The only field ``DraftStore/syncFromServer()`` orders by: a row
    /// whose `version` is not strictly greater than this is never adopted, however different its
    /// text.
    public var knownVersion: Int?
    /// What the row held immediately before the most recent write or discard this device knows
    /// about — the one-level undo the composer's plus menu offers as "Restore earlier version",
    /// shown only when this is non-empty and differs from `text`. Adopted from any row, write or
    /// discard response whose version is not older than `knownVersion`, independent of whether
    /// `text` itself is dirty — it is informational, like `attachments`, never something a local
    /// edit needs to protect.
    public var previousText: String?
    /// Files uploaded onto this draft — by this device or another one, indistinguishably: the
    /// point of uploading on stage rather than at send is composing one message from several
    /// devices at once, so a phone must see what a laptop just added before either sends.
    public var attachments: [DraftAttachment] = []

    public init(
        text: String, sessionType: String?, workingDir: String?, model: String? = nil, thinking: String? = nil,
        knownVersion: Int? = nil, previousText: String? = nil, attachments: [DraftAttachment] = []
    ) {
        self.text = text
        self.sessionType = sessionType
        self.workingDir = workingDir
        self.model = model
        self.thinking = thinking
        self.knownVersion = knownVersion
        self.previousText = previousText
        self.attachments = attachments
    }

    public static let empty = DraftEntry(text: "", sessionType: nil, workingDir: nil)
}
