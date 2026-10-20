import AVFoundation
import PAIKit

/// Turns an `EarconKind` into audio (`Earcon.samples`, PAIKit — pure synthesis) and plays it.
///
/// A dictation take plays its cues through `AVAudioPlayer`, never through the capture engine:
/// a cue fires from wherever a take hits trouble (a dropped socket, a backfill finishing after the
/// take ended), and an `AVAudioPlayerNode` started on that engine raises an Objective-C exception
/// whenever the engine is stopped or the node's connection is not usable yet — which Swift cannot
/// catch. `AVAudioPlayer` reports every failure as a thrown error or a `false` return instead.
/// It plays through the shared session, so the session dictation configures (`.playAndRecord`
/// with `.defaultToSpeaker`, which "continues with the Silent switch set to silent") keeps a cue
/// audible on the speaker with the ringer off.
///
/// A call with Computer plays its cues through `ComputerAudioIO`'s already playing node, which
/// only ever schedules buffers.
struct EarconPlayer {
    /// High enough for `Earcon`'s melodic tones (up to ~1.2kHz) to sound clean, matching the rate
    /// TTS playback already uses elsewhere in this app rather than inventing a third. It is also
    /// the protocol's own downlink rate, so a call's engine plays a cue without converting.
    static let sampleRate: Double = 24_000

    private let render: @MainActor ([Int16], Double) -> Void

    init(sessionPlayer: EarconSessionPlayer) {
        render = { samples, rate in sessionPlayer.play(samples: samples, sampleRate: rate) }
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

/// Plays cues as WAV data through `AVAudioPlayer`. Each player is held until it has finished,
/// since a released `AVAudioPlayer` stops mid-sound.
@MainActor
final class EarconSessionPlayer {
    private var playing: [AVAudioPlayer] = []

    func play(samples: [Int16], sampleRate: Double) {
        guard !samples.isEmpty else { return }
        playing.removeAll { !$0.isPlaying }
        let wav = PcmWavWriter.wrap(pcm16le: samples, sampleRate: Int(sampleRate))
        do {
            let player = try AVAudioPlayer(data: wav)
            guard player.play() else {
                AppVoiceDiagnosticsLog.shared.log(.warning, .audioSession, "earcon did not start playing")
                return
            }
            playing.append(player)
        } catch {
            AppVoiceDiagnosticsLog.shared.log(.warning, .audioSession, "earcon player unavailable: \(error)")
        }
    }
}
