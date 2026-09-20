import Foundation
import PAIKit

/// Turns an `EarconKind` into audio (`Earcon.samples`, PAIKit — pure synthesis) and hands the
/// samples to whichever audio engine is currently running.
///
/// Which engine that is depends on what the phone is doing: a dictation take runs
/// `MicrophoneCapture`'s, a call with Computer runs `ComputerAudioIO`'s, and only one of them is
/// live at a time. Routing through a running capture session rather than opening a separate one
/// is what makes a cue audible with the ringer switch on silent — see `MicrophoneCapture.playEarcon`'s
/// own doc comment for the mechanism, which is why this plays through an engine at all rather
/// than through a simpler system sound.
struct EarconPlayer {
    /// High enough for `Earcon`'s melodic tones (up to ~1.2kHz) to sound clean, matching the rate
    /// TTS playback already uses elsewhere in this app rather than inventing a third. It is also
    /// the protocol's own downlink rate, so a call's engine plays a cue without converting.
    static let sampleRate: Double = 24_000

    private let render: @MainActor ([Int16], Double) -> Void

    init(capture: MicrophoneCapture) {
        render = { samples, rate in capture.playEarcon(samples: samples, sampleRate: rate) }
    }

    init(audioIO: ComputerAudioIO) {
        render = { samples, _ in
            var data = Data(capacity: samples.count * 2)
            for sample in samples {
                let le = sample.littleEndian
                data.append(UInt8(truncatingIfNeeded: le))
                data.append(UInt8(truncatingIfNeeded: le >> 8))
            }
            audioIO.play(pcm16le: data, onFinished: {})
        }
    }

    @MainActor
    func play(_ kind: EarconKind) {
        render(Earcon.samples(kind: kind, sampleRate: Self.sampleRate), Self.sampleRate)
    }
}
