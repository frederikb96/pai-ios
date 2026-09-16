import PAIKit

/// Turns an `EarconKind` into audio (`Earcon.samples`, PAIKit — pure synthesis) and plays it
/// through `MicrophoneCapture`'s own `AVAudioEngine`. Routing through the capture session rather
/// than opening a separate one is what makes a cue audible with the ringer switch on silent —
/// see `MicrophoneCapture.playEarcon`'s own doc comment for the mechanism.
struct EarconPlayer {
    /// High enough for `Earcon`'s melodic tones (up to ~1.2kHz) to sound clean, matching the rate
    /// TTS playback already uses elsewhere in this app rather than inventing a third.
    static let sampleRate: Double = 24_000

    private let capture: MicrophoneCapture

    init(capture: MicrophoneCapture) {
        self.capture = capture
    }

    func play(_ kind: EarconKind) {
        let samples = Earcon.samples(kind: kind, sampleRate: Self.sampleRate)
        capture.playEarcon(samples: samples, sampleRate: Self.sampleRate)
    }
}
