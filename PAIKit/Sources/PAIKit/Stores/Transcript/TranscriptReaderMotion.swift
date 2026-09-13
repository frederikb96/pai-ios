import Foundation

/// Whether the transcript is moving because the reader moved it — a drag, or the deceleration a
/// drag left behind — as opposed to one of the app's own scrolls: a jump, a bottom landing, a hold
/// re-asserting, following new output.
///
/// ``EdgeFollowLatch`` needs this to tell a reader returning to the end from the app passing
/// through it. An animated jump that starts at the bottom emits its first scroll samples still
/// within the re-pin distance of the bottom, and a jump to a target in the last screen is clamped
/// to the bottom outright; both used to re-arm following, so the next live event carried the
/// reader straight back down from the message a notification had just landed them on.
///
/// Fed from the scroll view's own drag and deceleration callbacks rather than read off its
/// `isDragging`/`isDecelerating` flags, so that a programmatic write interrupting a fling is known
/// to end the reader's motion instead of depending on how UIKit reports that case.
public struct TranscriptReaderMotion: Equatable, Sendable {
    public private(set) var isReaderDriven = false

    public init() {}

    public mutating func beganDragging() {
        isReaderDriven = true
    }

    public mutating func endedDragging(willDecelerate: Bool) {
        if !willDecelerate { isReaderDriven = false }
    }

    public mutating func endedDecelerating() {
        isReaderDriven = false
    }

    /// The app is about to move the viewport itself. Whatever the reader was doing has been
    /// overridden, so nothing sampled after this is theirs until they touch the list again.
    public mutating func appScrolled() {
        isReaderDriven = false
    }
}
