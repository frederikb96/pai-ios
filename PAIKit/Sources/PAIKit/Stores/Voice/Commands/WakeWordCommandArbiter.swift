import Foundation

/// Collapses a burst of ``CommandEvent``s that fire within a short span of each other into the
/// single highest-scoring one. Several of the five offline classifiers share the same first word
/// ("Kai") and can genuinely all cross their own threshold for one spoken utterance, sometimes in
/// the very same `WakeWordCommandGate.detect(scores:atOffset:)` round, sometimes a round or two
/// later as the shared rolling window slides a little further past it — `WakeWordCommandGate`
/// already debounces a *repeated* firing of the *same* command; this is the layer above it that
/// decides between several *different* commands detected almost simultaneously, since a human
/// speaks one command phrase at a time and every classifier the same audio happens to cross for
/// besides the intended one is noise around it, not a second command.
public struct WakeWordCommandArbiter: Sendable {
    /// How long a window stays open once its first candidate arrives before the winner is
    /// released — wide enough to cover a co-fire spread across consecutive prediction rounds
    /// (observed ~100ms apart), short enough that a genuinely deliberate second command a moment
    /// later is never folded into the first one's window.
    public static let defaultWindowSeconds: TimeInterval = 0.2

    private let windowSamples: Int
    private var pending: [CommandEvent] = []
    private var windowStartOffset: Int?

    public init(sampleRate: Double, windowSeconds: TimeInterval = WakeWordCommandArbiter.defaultWindowSeconds) {
        self.windowSamples = Int(sampleRate * windowSeconds)
    }

    /// Called once per prediction round, even when `newEvents` is empty — an empty round is what
    /// lets a still-open window eventually close once nothing new has arrived for it. Folds
    /// `newEvents` into whatever window is currently open (opening a fresh one if none is), then
    /// releases the single highest-confidence candidate once `atOffset` has moved `windowSamples`
    /// past the window's own start. `nil` on every round that neither opens nor closes a window.
    ///
    /// `applicable` says which commands mean anything right now: a co-firing "start" while
    /// recording must not beat the "send" that was actually said, so only applicable candidates
    /// compete, and a window holding none releases nothing.
    public mutating func observe(
        newEvents: [CommandEvent], atOffset: Int, applicable: (CommandKind) -> Bool = { _ in true }
    ) -> CommandEvent? {
        for event in newEvents {
            if windowStartOffset == nil { windowStartOffset = event.atOffset }
            pending.append(event)
        }
        guard let start = windowStartOffset, atOffset - start >= windowSamples else { return nil }
        defer {
            pending = []
            windowStartOffset = nil
        }
        return pending.filter { applicable($0.kind) }.max { $0.confidence < $1.confidence }
    }
}
