import Foundation

/// The start/next/stop sequencing for one wake-word sample recording run — a burst of takes
/// recorded back-to-back under one `kind` and one `label`, each finalized the instant Freddy taps
/// Next so the next take can begin immediately. That rhythm is the whole point of the screen this
/// drives (`WakeWordSampleCaptureController`, `PAI/`): say "Computer", tap, say it again, with as
/// little waiting between the two as the hardware allows.
///
/// Holds no audio and touches no clock, disk or `AVAudioEngine` of its own — every finished take
/// is handed in as an already-built `WakeWordSample`, which is what makes this provable without a
/// device. The controller owns capture and timing; this owns only whether a `next()`/`stop()` is
/// even valid to call right now, and the ordered list of takes a run has produced so far.
public struct WakeWordSampleRun: Equatable, Sendable {
    public enum RunError: Error, Equatable {
        /// `next()` or `stop()` called after the run's own `stop()` already ran — there is no
        /// open take left to finish.
        case notRunning
    }

    public let kind: WakeWordSample.Kind
    public let label: String
    /// Every take finished in this run so far, oldest first. A take that produced no audio (an
    /// instant double-tap, say) is never appended — `next`/`stop` are passed `nil` for one, per
    /// their own doc comments.
    public private(set) var completedSamples: [WakeWordSample] = []
    /// 1-based position of the take currently open. `nil` once `stop()` has run — no further take
    /// may open on this value, and a fresh `WakeWordSampleRun` is what `startRun` makes instead.
    public private(set) var currentTakeIndex: Int?

    /// A run starts already recording its first take — there is no separate "armed" state to
    /// enter, matching Freddy's own description of the flow: tapping Start begins the first take
    /// immediately.
    public init(kind: WakeWordSample.Kind, label: String) {
        self.kind = kind
        self.label = label
        currentTakeIndex = 1
    }

    /// Ends the take open since `init`/the previous `next`, appends it (unless it produced no
    /// audio), and immediately opens the next one.
    @discardableResult
    public mutating func next(finishing sample: WakeWordSample?) throws -> Int {
        guard let index = currentTakeIndex else { throw RunError.notRunning }
        if let sample { completedSamples.append(sample) }
        let nextIndex = index + 1
        currentTakeIndex = nextIndex
        return nextIndex
    }

    /// Ends the take open since `init`/the last `next` and ends the run. No further take can be
    /// opened on this value afterwards.
    public mutating func stop(finishing sample: WakeWordSample?) throws {
        guard currentTakeIndex != nil else { throw RunError.notRunning }
        if let sample { completedSamples.append(sample) }
        currentTakeIndex = nil
    }
}
