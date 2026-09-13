import Foundation

/// Whether the transcript is moving because the reader moved it — a drag, or the deceleration a
/// drag left behind — as opposed to one of the app's own scrolls: a jump, a bottom landing, a hold
/// re-asserting, following new output.
///
/// ``EdgeFollowLatch`` needs this to tell a reader returning to the end from the app passing
/// through it. A jump to a target in the last screen — where a notification's newest message
/// usually is — is clamped onto the bottom, so the sample it reports reads "at the edge"; taken as
/// the reader's, that re-armed following, and the next live message carried the reader straight
/// back down off the one they had just been landed on. Every other programmatic write reports
/// samples the same way, so none of them may count.
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
