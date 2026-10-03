import Foundation

/// Decides what a sample run does when the audio engine reports a configuration change.
///
/// An engine reconfigures itself for reasons that leave the microphone untouched — above all a
/// Bluetooth headset switching from its output-only profile to its two-way one a moment after
/// capture starts, which changes the input's format but not the device. A run therefore stops
/// only when the input becomes a different device after the route has settled; every other
/// change is a restart of capture against the new format.
public struct MicrophoneRouteGuard: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        /// Same microphone (or still settling): rebuild capture in place and keep recording.
        case restartCapture
        /// A different microphone, or none: the run's one-microphone model no longer holds.
        case endRun
    }

    /// How long after capture starts a route change is still the start-up handshake rather than
    /// a device change.
    public static let settleSeconds: TimeInterval = 3

    private var baseline: String?
    private var startedAt: Date

    /// `input` is a stable identifier of the current input port (its uid), not its display name.
    public init(input: String?, startedAt: Date) {
        baseline = input
        self.startedAt = startedAt
    }

    public mutating func engineReconfigured(input: String?, now: Date) -> Decision {
        if now.timeIntervalSince(startedAt) < Self.settleSeconds {
            baseline = input
            return .restartCapture
        }
        guard let input, input == baseline else { return .endRun }
        return .restartCapture
    }
}
