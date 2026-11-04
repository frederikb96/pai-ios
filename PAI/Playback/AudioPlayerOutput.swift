import AVFoundation
import Foundation
import PAIKit

/// The speaker behind the playback engine: one segment file in an `AVAudioPlayer` at a time.
///
/// The audio session is set to `.playback` (spoken audio) when a segment is loaded, which is what
/// lets a reply keep going with the screen locked and sound with the silent switch on; the app's
/// `UIBackgroundModes` already carries `audio`. A phone call, another app taking the speaker, the
/// headset or the lock screen pausing it, and headphones being unplugged all end in
/// `onInterrupted`, after which only a press on Play resumes: a reply that started talking again
/// on its own after a call would be a surprise.
@MainActor
final class AudioPlayerOutput: NSObject, PlaybackOutput, AVAudioPlayerDelegate {
    var onTick: (@MainActor () -> Void)?
    var onFinished: (@MainActor () -> Void)?
    var onInterrupted: (@MainActor () -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) {
                [weak self] notification in
                let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                MainActor.assumeIsolated { self?.systemPaused() }
            })
        observers.append(
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) {
                [weak self] notification in
                let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                guard raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                MainActor.assumeIsolated { self?.systemPaused() }
            })
    }

    var positionMs: Int {
        Int(((player?.currentTime ?? 0) * 1000).rounded())
    }

    func load(_ data: Data, atMs offsetMs: Int, rate: Double) throws -> Int {
        stopTimer()
        try session.setCategory(.playback, mode: .spokenAudio)
        let next = try AVAudioPlayer(data: data)
        next.delegate = self
        next.enableRate = true
        next.rate = Float(rate)
        next.prepareToPlay()
        next.currentTime = Double(offsetMs) / 1000
        player = next
        return Int((next.duration * 1000).rounded())
    }

    func play() throws {
        guard let player else { throw PaiError.transport("There is no audio to play.") }
        try session.setActive(true)
        guard player.play() else { throw PaiError.transport("The audio could not be played.") }
        startTimer()
    }

    func pause() {
        player?.pause()
        stopTimer()
    }

    func seek(toMs offsetMs: Int) {
        player?.currentTime = Double(offsetMs) / 1000
    }

    func setRate(_ rate: Double) {
        player?.rate = Float(rate)
    }

    func clear() {
        stopTimer()
        player?.stop()
        player = nil
    }

    private func systemPaused() {
        guard let player, player.isPlaying else { return }
        player.pause()
        stopTimer()
        onInterrupted?()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick?() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stopTimer()
            self.onFinished?()
        }
    }
}
