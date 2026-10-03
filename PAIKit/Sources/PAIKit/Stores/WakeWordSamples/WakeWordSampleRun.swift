import Foundation

/// One recorded take waiting on this phone — its WAV beside it under `fileName` until the backend
/// has it.
public struct WakeWordPendingTake: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    /// 1-based position in its run.
    public let index: Int
    /// ISO-8601, UTC.
    public let recordedAt: String
    public let durationMs: Int
    public let fileName: String

    public init(id: String, index: Int, recordedAt: String, durationMs: Int, fileName: String) {
        self.id = id
        self.index = index
        self.recordedAt = recordedAt
        self.durationMs = durationMs
        self.fileName = fileName
    }
}

/// The start/next/stop sequencing for one wake-word sample run — a burst of takes recorded
/// back-to-back under one kind and one label, each finished the instant Next is tapped so the next
/// take begins at once. That rhythm is the whole point of the screen this drives: say "Computer",
/// tap, say it again, with as little waiting between the two as the hardware allows.
///
/// Holds no audio and touches no clock, disk or audio engine — every finished take is handed in
/// already built, which is what makes this provable without a device.
public struct WakeWordSampleRun: Equatable, Sendable {
    public enum RunError: Error, Equatable {
        /// `next()` or `stop()` called after the run's own `stop()` already ran — there is no
        /// open take left to finish.
        case notRunning
    }

    public let id: String
    public let kind: WakeWordSampleKind
    public let label: String
    /// Every take finished in this run so far, oldest first. A take that produced no audio (an
    /// instant double-tap, say) is never appended — `next`/`stop` are passed `nil` for one.
    public private(set) var completedTakes: [WakeWordPendingTake] = []
    /// 1-based position of the take currently open. `nil` once `stop()` has run.
    public private(set) var currentTakeIndex: Int?

    /// A run starts already recording its first take — tapping Start begins the first take
    /// immediately, with no separate armed state.
    public init(id: String, kind: WakeWordSampleKind, label: String) {
        self.id = id
        self.kind = kind
        self.label = label
        currentTakeIndex = 1
    }

    /// Ends the open take, appends it (unless it produced no audio), and opens the next one.
    @discardableResult
    public mutating func next(finishing take: WakeWordPendingTake?) throws -> Int {
        guard let index = currentTakeIndex else { throw RunError.notRunning }
        if let take { completedTakes.append(take) }
        let nextIndex = index + 1
        currentTakeIndex = nextIndex
        return nextIndex
    }

    /// Ends the open take and the run. No further take can be opened on this value afterwards.
    public mutating func stop(finishing take: WakeWordPendingTake?) throws {
        guard currentTakeIndex != nil else { throw RunError.notRunning }
        if let take { completedTakes.append(take) }
        currentTakeIndex = nil
    }
}
