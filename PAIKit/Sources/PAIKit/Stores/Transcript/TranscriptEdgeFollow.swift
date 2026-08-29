import Foundation

/// Whether the transcript should keep following newly-arriving content — a latch, not a
/// distance, and deliberately asymmetric: it takes more distance to count as "scrolled away"
/// than it does to count as "back".
///
/// A single shared threshold re-pins on the very next scroll event after a short flick up and
/// snaps the view straight back down, which is the single most common complaint about chat UIs.
/// Kept as pure state — the geometry (turning a raw `contentOffset` into "distance from the true
/// bottom", and driving the actual scroll) is the view's job; this only answers "should new
/// output keep following right now?".
///
/// Deliberately **not** the same question as "is a row currently at the live edge" — see
/// ``isAtLiveEdge(distanceFromBottom:)``. That is computed fresh from geometry every time it is
/// asked, because it protects nothing and has no history to protect. This type's whole reason to
/// exist is the opposite: it stays sticky across a scroll that only *approaches* the edge, so
/// growth alone can never flip it, only a deliberate gesture or a genuine return to the bottom
/// can.
public struct EdgeFollowLatch: Equatable, Sendable {
    /// Being within this many points of the bottom is enough to report the live edge — used for
    /// the stateless ``isAtLiveEdge(distanceFromBottom:)`` check (jump-to-bottom visibility, and
    /// an anchor's own "was this the bottom" flag), not for re-arming the latch itself.
    public static let pinThreshold: Double = 70
    /// How close the reader must come back to re-arm the latch after scrolling away. Narrower
    /// than ``pinThreshold`` on purpose — see the type's doc comment.
    public static let repinThreshold: Double = 4

    public private(set) var isPinned: Bool

    public init(isPinned: Bool = true) {
        self.isPinned = isPinned
    }

    /// A deliberate gesture away from the bottom — wheel scrolling up, a touch drag that moves
    /// content down, or a keyboard scroll toward the top. Un-pins immediately regardless of the
    /// current position; classifying which raw gesture counts is the view's job (see
    /// `references/native.md` in the `scrolling` skill).
    public mutating func recordScrollAway() {
        isPinned = false
    }

    /// A scroll-position sample, in points of remaining distance to the true bottom. Only
    /// re-arms the latch — it never un-pins one, and growth while already unpinned does nothing,
    /// which is also the complete defense against a live append moving content under a reader
    /// who has scrolled up: nothing here reacts to it.
    public mutating func recordDistanceFromBottom(_ distance: Double) {
        guard !isPinned, distance <= Self.repinThreshold else { return }
        isPinned = true
    }

    /// Whether a row this far from the bottom counts as "the live edge" — a stateless geometry
    /// check, independent of ``isPinned``. Two different questions that happen to look
    /// interchangeable at the exact moment a reader is at the bottom: this one has no memory, so
    /// it is safe to compute for an anchor being recorded, or for whether to show a jump-to-bottom
    /// control, without disturbing the latch above.
    public static func isAtLiveEdge(distanceFromBottom distance: Double) -> Bool {
        distance <= pinThreshold
    }
}
