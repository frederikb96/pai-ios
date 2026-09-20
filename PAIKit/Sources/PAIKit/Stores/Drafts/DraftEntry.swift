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
    /// A `claude --model` alias for the next session — only meaningful on ``DraftKey/newSession``,
    /// alongside `sessionType`/`workingDir`. `nil` lets Claude Code pick the plan's own default.
    public var model: String?
    /// A `claude --effort` level for the next session — only meaningful alongside `model` above.
    /// `nil` lets Claude Code pick the plan's own default.
    public var thinking: String?
    /// `updated_at` of the server version this entry was last reconciled with.
    ///
    /// Compared for **inequality, never ordered**, in ``DraftStore/syncFromServer()`` — the
    /// device's clock and the server's do not have to agree for that comparison to be correct.
    public var remoteUpdatedAt: String?
    /// Every take's own region, in the order its take was opened — never written by typing, only
    /// by a machine (live dictation, server-side; a backfill recovering a stretch the live path
    /// missed, client-side). See ``displayText``.
    public var regions: [DraftRegion] = []
    /// Files uploaded onto this draft — by this device or another one, indistinguishably: the
    /// point of uploading on stage rather than at send is composing one message from several
    /// devices at once, so a phone must see what a laptop just added before either sends.
    public var attachments: [DraftAttachment] = []

    public init(
        text: String, sessionType: String?, workingDir: String?, model: String? = nil, thinking: String? = nil,
        remoteUpdatedAt: String?, regions: [DraftRegion] = [], attachments: [DraftAttachment] = []
    ) {
        self.text = text
        self.sessionType = sessionType
        self.workingDir = workingDir
        self.model = model
        self.thinking = thinking
        self.remoteUpdatedAt = remoteUpdatedAt
        self.regions = regions
        self.attachments = attachments
    }

    public static let empty = DraftEntry(text: "", sessionType: nil, workingDir: nil, remoteUpdatedAt: nil)

    /// What every client renders: `text` followed by each **still-open** region's own text, in
    /// the order their takes were opened — plain concatenation, never an offset into either
    /// string, matching the backend's own `compose_draft_text`
    /// (`pai-cloud/backend/src/pai_cloud/repository.py`) and the web's own renderer
    /// (`pai-cloud/web/src/stores/drafts.ts`).
    ///
    /// 🚨 **A closed region must not contribute, and rendering one is not a harmless extra.**
    /// Closing a region folds its text into `text` server-side, in the same transaction, and
    /// leaves the region row standing with its words still in it — so a renderer that counts
    /// closed regions draws every finished dictation take twice, once from `text` and once from
    /// the region it was folded out of. Freddy hit exactly that: each take doubled, and a delete
    /// racing a fold then grew it a copy at a time until the composer was a wall of the same
    /// sentence.
    ///
    /// Each region's own contribution carries the `stt-rec: ` marker once, at its own start — the
    /// backend writes a region's raw transcribed text with no prefix at all (`DraftRegionSink`
    /// never adds one), so this is the one place that marks it as machine-produced, at the same
    /// per-take granularity the ElevenLabs-era pipeline always prefixed at.
    public var displayText: String {
        let parts =
            [text]
            + regions.filter { $0.state == "open" && !$0.text.isEmpty }
            .map { "\(VoiceRecordingResult.sttPrefix)\($0.text)" }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    public var hasOpenRegions: Bool { regions.contains { $0.state == "open" } }
}
