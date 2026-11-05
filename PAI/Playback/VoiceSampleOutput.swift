import AVFoundation
import Foundation
import PAIKit

/// The speaker behind Settings' Try button: one short sample in an `AVAudioPlayer`.
///
/// Uses the same `.playback` audio session as a reply, so a sample is heard with the silent switch
/// on; it is separate from ``AudioPlayerOutput`` so trying a voice never replaces the reply in hand.
@MainActor
final class VoiceSampleOutput: NSObject, VoiceSamplePlayer, AVAudioPlayerDelegate {
    var onFinished: (@MainActor () -> Void)?

    private var player: AVAudioPlayer?

    func play(_ data: Data) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        let next = try AVAudioPlayer(data: data)
        next.delegate = self
        player = next
        guard next.play() else { throw PaiError.transport("The sample could not be played.") }
    }

    func stop() {
        player?.stop()
        player = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.onFinished?() }
    }
}
