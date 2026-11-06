import AVFoundation
import Foundation

/// Silence played on a loop while ``PlaybackKeepAlive`` holds: a backgrounded app with the `audio`
/// mode keeps running only while it is actually playing, and autoplay needs it running to start the
/// next reply. Same `.playback`/`.spokenAudio` session as ``AudioPlayerOutput``, so the two play
/// side by side and the reply's own category change is a no-op.
///
/// Another app's audio, a call, or headphones being unplugged end it through `onEnded`; nothing
/// resumes it, the same as a reply.
@MainActor
final class SilentKeepAlive {
    var onEnded: (@MainActor () -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) {
                [weak self] notification in
                let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                MainActor.assumeIsolated { self?.endedBySystem() }
            })
        observers.append(
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) {
                [weak self] notification in
                let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                guard raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                MainActor.assumeIsolated { self?.endedBySystem() }
            })
    }

    var isPlaying: Bool { player?.isPlaying ?? false }

    var otherAppIsPlaying: Bool { session.isOtherAudioPlaying }

    /// Starts the loop; answers whether it is playing.
    @discardableResult
    func start() -> Bool {
        if isPlaying { return true }
        do {
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            let next = try player ?? AVAudioPlayer(data: Self.silence)
            next.numberOfLoops = -1
            player = next
            return next.play()
        } catch {
            return false
        }
    }

    /// Stops the loop and leaves the audio session as it is: a reply may be playing on it.
    func stop() {
        player?.stop()
    }

    private func endedBySystem() {
        guard isPlaying else { return }
        player?.stop()
        onEnded?()
    }

    /// One second of 8 kHz, 16-bit mono zeros as a WAV file.
    private static let silence: Data = {
        let sampleRate: UInt32 = 8000
        let dataBytes = sampleRate * 2
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        wav.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataBytes))
        wav.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(sampleRate)
        append(sampleRate * 2)
        append(UInt16(2))
        append(UInt16(16))
        wav.append(contentsOf: Array("data".utf8))
        append(dataBytes)
        wav.append(Data(count: Int(dataBytes)))
        return wav
    }()
}
