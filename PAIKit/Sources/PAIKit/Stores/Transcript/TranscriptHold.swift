import Foundation

/// Supplies "now" to anything on the transcript path that reasons about elapsed time — a
/// protocol rather than a bare closure so a call site can hand over ``SystemTranscriptClock``
/// once, while a test hands over a fake it advances by hand instead of sleeping.
public protocol TranscriptClock: Sendable {
    func now() -> Date
}

public struct SystemTranscriptClock: TranscriptClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// What a transcript position is being held against, while the layout underneath it is still
/// settling.
public enum TranscriptHoldKind: Equatable, Sendable {
    case bottom
    case restore(messageId: Int)
    case search(messageId: Int)
}

/// A held scroll position: a target, and how long it stays defended.
///
/// A restore (or a jump to the bottom, or a search jump) is one absolute write, but the rows it
/// targeted are virtualized — later rows mounting under it move it. A single write therefore
/// lands correctly and is quietly wrong a moment later, and no fixed settling time covers every
/// kind of content in general; re-asserting the same target every time the layout changes, until
/// this window elapses, converges instead of accumulating error. The window is the one thing
/// this type owns; re-driving the actual scroll on every frame is the view's job.
public struct TranscriptHold: Equatable, Sendable {
    /// All three kinds share one duration in the web (`RESTORE_FRAME_MS`, `SEARCH_HOLD_MS`,
    /// `BOTTOM_HOLD_MS`, all 1500ms) — kept here as one constant rather than three that could
    /// drift apart.
    public static let duration: TimeInterval = 1.5

    public let kind: TranscriptHoldKind
    private let expiresAt: Date

    public init(kind: TranscriptHoldKind, now: Date) {
        self.kind = kind
        self.expiresAt = now.addingTimeInterval(Self.duration)
    }

    /// Re-arms the same hold for another full window. Call this every time the layout it is
    /// protecting settles again (a resize, a card expanding) — never once and forgotten.
    public func extended(now: Date) -> TranscriptHold {
        TranscriptHold(kind: kind, now: now)
    }

    public func isActive(now: Date) -> Bool {
        now < expiresAt
    }
}

/// Owns the one active hold, if any, for a transcript. A hold that never releases reads as a
/// frozen page — release it on any deliberate gesture or a jump to the edge, never only by
/// letting the window expire.
@MainActor
public final class TranscriptHoldController {
    public private(set) var hold: TranscriptHold?
    private let clock: TranscriptClock

    public init(clock: TranscriptClock = SystemTranscriptClock()) {
        self.clock = clock
    }

    public func begin(_ kind: TranscriptHoldKind) {
        hold = TranscriptHold(kind: kind, now: clock.now())
    }

    public func extend() {
        hold = hold?.extended(now: clock.now())
    }

    public func release() {
        hold = nil
    }

    /// Whether a hold is currently defending a position. `false` once the window has elapsed,
    /// even if ``release()`` was never called — but a caller that keeps calling ``extend()``
    /// every time the layout settles never lets it lapse on its own.
    public var isActive: Bool {
        guard let hold else { return false }
        return hold.isActive(now: clock.now())
    }
}
