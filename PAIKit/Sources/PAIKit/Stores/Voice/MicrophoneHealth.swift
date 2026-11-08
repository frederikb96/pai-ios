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
    /// Buffers are arriving and the latest one rose to speech in this room (`MicrophoneLevelMeter`).
    case hearing(level: Double)
    /// Buffers are arriving; the latest did not rise to speech. Normal — a pause
    /// between sentences looks exactly like this.
    case quiet
    /// No buffer has arrived within the stall window — the same absence
    /// `VoiceRecorderController`'s own capture watchdog already detects, surfaced here for
    /// display rather than for recovery.
    case notHearing

    /// The state for the latest chunk: `stalled` (no buffer within the stall window) wins over
    /// whatever the last reading said, and otherwise the meter's own judgement of whether the
    /// chunk rose to speech in this room decides between hearing and quiet.
    public init(stalled: Bool, reading: MicrophoneLevelMeter.Reading) {
        if stalled {
            self = .notHearing
        } else if reading.heard {
            self = .hearing(level: reading.level)
        } else {
            self = .quiet
        }
    }
}
