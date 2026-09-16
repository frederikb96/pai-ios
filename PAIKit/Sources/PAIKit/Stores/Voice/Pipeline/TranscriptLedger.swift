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

    public init(
        takeId: String, mode: VoiceMode, sampleRate: Int, draftKey: String?, preText: String,
        segments: [Segment] = [], capturedUpTo: Int = 0, gaps: [Gap] = [],
        boundaries: [MessageBoundary] = [], collecting: [SampleRange] = [],
        events: [PipelineEvent] = [], delivered: Bool = false
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
