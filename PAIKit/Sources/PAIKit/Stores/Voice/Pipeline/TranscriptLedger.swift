import Foundation

/// Which of the two takes a ledger belongs to. The durable pipeline is one implementation for
/// both, but a few fields only mean something for one of them: `call`'s `collecting` ranges and
/// `boundaries` are meaningless for `microphone`, whose whole take is implicitly one collecting
/// range with no boundaries at all.
public enum VoiceMode: String, Codable, Sendable, Equatable {
    case microphone, call
}

/// One word, at its place in the take. Never a connection's own elapsed seconds — that is
/// `RealtimeWordTimestamp` (`VoiceRealtimeProtocol.swift`), before `SessionTimeline` converts it
/// to the take offsets this type carries.
public struct Word: Codable, Sendable, Equatable {
    public let range: SampleRange
    public let text: String
    public let logprob: Double?

    public init(range: SampleRange, text: String, logprob: Double? = nil) {
        self.range = range
        self.text = text
        self.logprob = logprob
    }
}

/// One committed stretch of transcript, addressed by the take samples it covers. `words` is
/// `nil` when its source never carried timestamps — the no-timestamps fallback `SeamMerge` falls
/// back to when the server ever sends only a plain `committed_transcript`.
public struct Segment: Codable, Sendable, Equatable {
    /// Which pass produced this segment's text — `SeamMerge`'s precedence when two overlap runs
    /// `.batch` over `.liveBurst` over `.live`, in that order, because the batch model is better
    /// and saw the widest context.
    public enum Source: String, Codable, Sendable, Equatable {
        case live, liveBurst, batch, recovery
    }

    public let range: SampleRange
    public let text: String
    public let words: [Word]?
    public let source: Source

    public init(range: SampleRange, text: String, words: [Word]? = nil, source: Source) {
        self.range = range
        self.text = text
        self.words = words
        self.source = source
    }
}

/// A stretch of captured audio with no committed segment covering it yet — a work item that
/// survives a restart with its retry budget intact, not a hole recomputed on the fly from
/// `segments` and the WAV header on every launch.
public struct Gap: Codable, Sendable, Equatable {
    public let range: SampleRange
    public let attempts: Int
    public let lastError: String?
    /// Past the backfill planner's retry budget on a stable link — surfaced in settings instead
    /// of retried forever.
    public let demoted: Bool

    public init(range: SampleRange, attempts: Int = 0, lastError: String? = nil, demoted: Bool = false) {
        self.range = range
        self.attempts = attempts
        self.lastError = lastError
        self.demoted = demoted
    }
}

/// A point in call mode's timeline where a message either was sent or should have been —
/// `collecting` (on `TranscriptLedger`) says which stretch of audio belongs to which boundary.
public struct MessageBoundary: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        /// The offline command engine heard "stop".
        case stop
        /// Recovery closed a stretch on Freddy's behalf after a call-mode take crashed mid-take;
        /// never sent automatically.
        case crashCut
        /// Reserved for a boundary this design does not yet create automatically.
        case autoSend
    }

    public let atOffset: Int
    public let kind: Kind
    public let sentMessageId: String?

    public init(atOffset: Int, kind: Kind, sentMessageId: String? = nil) {
        self.atOffset = atOffset
        self.kind = kind
        self.sentMessageId = sentMessageId
    }
}

/// The diagnostic record of one pipeline occurrence — a drop, a reconnect, a gap opening, a
/// backfill finishing. Kept for the recordings report JSON and for reconstructing a bad ride
/// without asking Freddy to remember it.
public struct PipelineEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        case drop, reconnect, mintFailed, serverNotice, gapOpened, backfillDone, paused, resumed
        case captureRestart
    }

    public let atOffset: Int
    public let wallClock: Date
    public let kind: Kind

    public init(atOffset: Int, wallClock: Date, kind: Kind) {
        self.atOffset = atOffset
        self.wallClock = wallClock
        self.kind = kind
    }
}

/// The durable record of one take's transcription: every sample range that has committed text,
/// every gap still open, and — in call mode — every message boundary. Addressed entirely in take
/// sample offsets, never wall-clock time.
///
/// A pure value: nothing here mutates itself, a caller always holds the next ledger as a new
/// value, matching `LedgerFile`'s atomic-write contract (temp file + rename), which only ever
/// replaces the whole file. `coveredUpTo`/gap-derivation over `segments` is deliberately not
/// here — that arithmetic lives beside `LedgerFile`, next to the code that actually needs it.
public struct TranscriptLedger: Codable, Sendable, Equatable {
    public let takeId: String
    public let mode: VoiceMode
    public let sampleRate: Int
    /// The draft a completed segment's text flows into — a session id in both modes. `nil` for a
    /// take recovery found on disk with no `RecordingMeta` to read it from.
    public let draftKey: String?
    /// What was already in the field when the take began — appended to, not replaced, and today
    /// lost on a crash; this is what recovery restores it from instead.
    public let preText: String
    public let segments: [Segment]
    /// Advisory only — the WAV header is the authoritative record of what has actually been
    /// captured. This is what recovery reads before the header is available, or agrees with it
    /// once it is.
    public let capturedUpTo: Int
    public let gaps: [Gap]
    public let boundaries: [MessageBoundary]
    /// The stretches between a "start" and a "stop" (call mode only) — only audio inside one of
    /// these is ever transcribed automatically or counted as a gap. `microphone` mode's whole
    /// take is implicitly one collecting range and never populates this.
    public let collecting: [SampleRange]
    public let events: [PipelineEvent]
    /// The assembled text has reached its draft or message. The rule for when a take's audio may
    /// ever be deleted reads this alongside `gaps.isEmpty`.
    public let delivered: Bool
    /// Sample ranges the durable pipeline treats as accounted for and never a gap: audio sent on
    /// a connection that later received any commit message (an acknowledgement that everything
    /// sent before it landed), and audio the silence gate deliberately withheld. Word extents are
    /// not this measure — an ordinary pause between sentences is silence inside an acknowledged
    /// stretch, not a hole in it. Optional so a ledger written before this field existed still
    /// decodes; read as empty, which means "nothing acknowledged yet" rather than "everything
    /// captured is fine" — the safe direction, same as every other crash-recovery default here.
    public let acknowledged: [SampleRange]?

    public init(
        takeId: String, mode: VoiceMode, sampleRate: Int, draftKey: String?, preText: String,
        segments: [Segment] = [], capturedUpTo: Int = 0, gaps: [Gap] = [],
        boundaries: [MessageBoundary] = [], collecting: [SampleRange] = [],
        events: [PipelineEvent] = [], delivered: Bool = false, acknowledged: [SampleRange]? = nil
    ) {
        self.takeId = takeId
        self.mode = mode
        self.sampleRate = sampleRate
        self.draftKey = draftKey
        self.preText = preText
        self.segments = segments
        self.capturedUpTo = capturedUpTo
        self.gaps = gaps
        self.boundaries = boundaries
        self.collecting = collecting
        self.events = events
        self.delivered = delivered
        self.acknowledged = acknowledged
    }
}

extension TranscriptLedger {
    /// Sample ranges covered by committed segments, merged and sorted — the single source
    /// `derivedGaps(capturedUpTo:)` and every reader of "what has text" reads from, rather than a
    /// second field that could disagree with `segments`.
    public var coveredRanges: [SampleRange] { Self.merge(segments.map(\.range)) }

    /// The ranges eligible to ever become a gap or be transcribed automatically — the whole
    /// captured take for `microphone` mode, only the stretches between a start and a stop for
    /// `call` mode (clamped to what has actually been captured, since a `collecting` range still
    /// open when the take ends would otherwise claim samples that do not exist yet).
    public func collectingBounds(capturedUpTo: Int) -> [SampleRange] {
        guard capturedUpTo > 0 else { return [] }
        switch mode {
        case .microphone:
            return [0..<capturedUpTo]
        case .call:
            return collecting.compactMap { range -> SampleRange? in
                let lower = min(range.lowerBound, capturedUpTo)
                let upper = min(range.upperBound, capturedUpTo)
                return lower < upper ? lower..<upper : nil
            }
        }
    }

    /// The gap list this ledger should hold right now: every stretch of captured, in-scope audio
    /// not yet `acknowledged` — never word extents, which is what silently turned an ordinary
    /// pause between sentences into a "gap" that backfill re-requested forever. Carries forward
    /// the attempt count, last error and demotion of whichever persisted `Gap` it overlaps — a
    /// retry budget must survive a restart, not reset because the hole was recomputed fresh. A
    /// gap now acknowledged is simply absent from the result; nothing here ever deletes a
    /// `Segment` or a persisted attempt count itself.
    ///
    /// `pendingLiveRange` is the stretch currently in flight on a healthy, still-recording
    /// connection (`VoiceRecordingSession.pendingLiveRange`) — captured and sent, but not yet
    /// acknowledged only because the server hasn't had a pause to commit it on yet. Excluded from
    /// gap consideration the same way `acknowledged` is, but without actually being acknowledged:
    /// it becomes a real gap the moment the caller stops passing it, which is exactly what a
    /// dropped or stopped connection does. Without this, a call mode cycle's own live edge reads
    /// as an open gap on every one-second ledger write, and the backfill loop keeps
    /// batch-transcribing speech ElevenLabs was about to commit on its own a moment later.
    public func derivedGaps(capturedUpTo: Int, pendingLiveRange: SampleRange? = nil) -> [Gap] {
        let bounds = collectingBounds(capturedUpTo: capturedUpTo)
        var settled = acknowledged ?? []
        if let pendingLiveRange, !pendingLiveRange.isEmpty { settled.append(pendingLiveRange) }
        let uncovered = Self.uncoveredRanges(in: bounds, covered: settled)
        return uncovered.map { range in
            if let previous = gaps.first(where: { $0.range.overlaps(range) }) {
                return Gap(
                    range: range, attempts: previous.attempts, lastError: previous.lastError,
                    demoted: previous.demoted
                )
            }
            return Gap(range: range)
        }
    }

    /// The one rule for when a take's audio may ever be deleted: no open gap, and its text has
    /// already reached the draft or message it belongs to. Retention (which takes the cap
    /// actually evicts) reads this before counting a take against its limit.
    public var mayBeDeleted: Bool { gaps.isEmpty && delivered }

    /// Folds fresh session output into the ledger — new live segments merged with whatever
    /// batch/recovery segments it already had, `acknowledged` extended with what the session has
    /// newly confirmed, and gaps re-derived against the new `capturedUpTo`. What every live write
    /// is built from: the periodic ledger loop while a take runs, and the final synchronous fold
    /// at `stop()` — the same function for both is what keeps the take's very last sentence from
    /// being dropped by whichever one happened to run last.
    public func folding(
        liveSegments: [Segment], capturedUpTo: Int, newlyAcknowledged: [SampleRange],
        collecting: [SampleRange]? = nil, pendingLiveRange: SampleRange? = nil
    ) -> TranscriptLedger {
        let recoveredSegments = segments.filter { $0.source == .batch || $0.source == .recovery }
        let mergedSegments = SeamMerge.merge(liveSegments + recoveredSegments)
        let mergedAcknowledged = Self.merge((acknowledged ?? []) + newlyAcknowledged)
        let resolvedCollecting = collecting ?? self.collecting
        let withoutGaps = TranscriptLedger(
            takeId: takeId, mode: mode, sampleRate: sampleRate, draftKey: draftKey, preText: preText,
            segments: mergedSegments, capturedUpTo: capturedUpTo, gaps: gaps, boundaries: boundaries,
            collecting: resolvedCollecting, events: events, delivered: delivered, acknowledged: mergedAcknowledged
        )
        return TranscriptLedger(
            takeId: takeId, mode: mode, sampleRate: sampleRate, draftKey: draftKey, preText: preText,
            segments: mergedSegments, capturedUpTo: capturedUpTo,
            gaps: withoutGaps.derivedGaps(capturedUpTo: capturedUpTo, pendingLiveRange: pendingLiveRange),
            boundaries: boundaries,
            collecting: resolvedCollecting, events: events, delivered: delivered, acknowledged: mergedAcknowledged
        )
    }

    /// Applies one backfill pass's outcome to the ledger's *current* state — never the snapshot
    /// the pass started reading from, which a network round trip can leave stale. `resolved`
    /// ranges (a `.segment` or `.noSpeechDetected` outcome) are subtracted from every gap they
    /// overlap in whatever `gaps` holds right now, not from a copy computed before the pass began
    /// — a gap that grew while the pass was in flight (a later fold pushed its far edge out) is
    /// narrowed to whatever sliver is still actually uncovered, rather than surviving unchanged
    /// because it no longer matches `resolved` exactly. That sliver is what the next pass, 300ms
    /// later, correctly re-requests instead of re-transcribing words this pass already covered.
    /// `failed` ranges get their attempt bumped against the *current* gap that still contains
    /// them. A gap opened fresh while the pass was in flight is untouched either way. `delivered`
    /// is deliberately not touched here — it means the text actually reached its destination,
    /// which only the caller who wrote it there knows.
    ///
    /// `resolved` ranges are also folded into `acknowledged` — a settled fact about the take,
    /// exactly as final as anything a live commit ever confirmed. Without this, the next ordinary
    /// `folding()` call (which recomputes `gaps` entirely fresh from `acknowledged`, never
    /// consulting `gaps`' own current, already-healed state) would silently reopen the very gap
    /// this pass just closed.
    public func applyingBackfill(
        newSegments: [Segment], resolved: [SampleRange], failed: [(range: SampleRange, error: String)]
    ) -> TranscriptLedger {
        let mergedSegments = SeamMerge.merge(segments + newSegments)
        var updatedGaps: [Gap] = []
        for gap in gaps {
            let remaining = Self.uncoveredRanges(in: [gap.range], covered: resolved)
            updatedGaps.append(
                contentsOf: remaining.map { range in
                    Gap(range: range, attempts: gap.attempts, lastError: gap.lastError, demoted: gap.demoted)
                })
        }
        for failure in failed {
            guard let index = updatedGaps.firstIndex(where: { $0.range.overlaps(failure.range) }) else { continue }
            updatedGaps[index] = BackfillPlanner.recordFailure(updatedGaps[index], error: failure.error)
        }
        let mergedAcknowledged = Self.merge((acknowledged ?? []) + resolved)
        return TranscriptLedger(
            takeId: takeId, mode: mode, sampleRate: sampleRate, draftKey: draftKey, preText: preText,
            segments: mergedSegments, capturedUpTo: capturedUpTo, gaps: updatedGaps, boundaries: boundaries,
            collecting: collecting, events: events, delivered: delivered, acknowledged: mergedAcknowledged
        )
    }

    /// Merges overlapping or adjacent ranges into a sorted, disjoint set.
    static func merge(_ ranges: [SampleRange]) -> [SampleRange] {
        let sorted = ranges.filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }
        var result: [SampleRange] = []
        for range in sorted {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// Every stretch of each `bound` range not covered by any range in `covered`.
    static func uncoveredRanges(in bounds: [SampleRange], covered: [SampleRange]) -> [SampleRange] {
        let coveredSorted = merge(covered)
        return bounds.flatMap { bound -> [SampleRange] in
            guard !bound.isEmpty else { return [] }
            var result: [SampleRange] = []
            var cursor = bound.lowerBound
            for range in coveredSorted {
                let lower = max(range.lowerBound, bound.lowerBound)
                let upper = min(range.upperBound, bound.upperBound)
                guard lower < upper else { continue }
                if lower > cursor { result.append(cursor..<lower) }
                cursor = max(cursor, upper)
            }
            if cursor < bound.upperBound { result.append(cursor..<bound.upperBound) }
            return result
        }
    }
}

/// What `RecordingMeta` (`DiagnosticRecords.swift`) shows about a take's transcription without
/// reading the ledger itself — the Settings › Recordings row's coverage line is built from this.
public struct TranscriptionMeta: Codable, Sendable, Equatable {
    /// Named `Coverage`, not `State` — the latter shadows SwiftUI's `@State` property wrapper for
    /// every file that imports this type alongside SwiftUI.
    public enum Coverage: String, Codable, Sendable, Equatable {
        case complete, pending, failed
    }

    public let coveredMs: Double
    public let gapMs: Double
    public let gapCount: Int
    public let state: Coverage
    public let delivered: Bool

    public init(coveredMs: Double, gapMs: Double, gapCount: Int, state: Coverage, delivered: Bool) {
        self.coveredMs = coveredMs
        self.gapMs = gapMs
        self.gapCount = gapCount
        self.state = state
        self.delivered = delivered
    }
}
