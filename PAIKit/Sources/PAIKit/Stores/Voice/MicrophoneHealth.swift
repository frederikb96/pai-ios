import Foundation

/// What the volume overlay shows — its job is not to show the volume, it is to answer "are my
/// words being kept?" while there is no live transcript to prove it any other way. Amplitude is
/// only the evidence; the state that actually matters is derived from two signals, never one:
/// whether buffers are arriving from the microphone at all, and — only once they are — how loud
/// the latest one was.
///
/// `.notHearing` is deliberately never derived from amplitude: quiet and dead both read as near
/// enough to zero, and the two must look different, since one is a normal room and the other is a
/// take capturing nothing. Only the absence of buffers arriving at all means the second one.
public enum MicrophoneHealthState: Equatable, Sendable {
    /// Buffers are arriving and the latest one reads above the quiet floor.
    case hearing(level: Double)
    /// Buffers are arriving; the latest reads at or below the quiet floor. Normal — a pause
    /// between sentences looks exactly like this.
    case quiet
    /// No buffer has arrived within the stall window — the same absence
    /// `VoiceRecorderController`'s own capture watchdog already detects, surfaced here for
    /// display rather than for recovery.
    case notHearing

    /// Below this, a buffer reads as `.quiet` rather than `.hearing` — a flat line for an
    /// ordinary silent room, not a decorative floor.
    public static let quietFloor = 0.02
}
