import Foundation
import Observation

/// What `PlaybackVoicesStore` needs from the API; `PaiApiClient` conforms structurally.
public protocol PlaybackVoicesApiClient: Sendable {
    func getPlaybackVoices() async throws -> PlaybackVoices
    func fetchPlaybackVoiceSample(provider: PlaybackProvider, voiceId: String) async throws -> Data
}

extension PaiApiClient: PlaybackVoicesApiClient {}

/// The speaker a voice sample plays through. The app implements it over `AVAudioPlayer`; tests
/// implement it with a fake. Everything happens on the main actor.
@MainActor
public protocol VoiceSamplePlayer: AnyObject {
    /// The sample played to its end.
    var onFinished: (@MainActor () -> Void)? { get set }
    func play(_ data: Data) throws
    func stop()
}

public enum VoiceSampleState: Sendable, Equatable {
    case idle, loading, playing
}

/// Which row of the voice picker a value stands on.
public enum PlaybackVoiceSelection: Sendable, Hashable {
    /// No voice of the person's own: the owner's default reads.
    case defaultVoice
    case listed(String)
    /// An id the account's list does not hold, typed by the person.
    case custom

    public static func of(_ value: String?, listed: [PlaybackVoiceChoice]) -> PlaybackVoiceSelection {
        guard let value, !value.isEmpty else { return .defaultVoice }
        return listed.contains { $0.voiceId == value } ? .listed(value) : .custom
    }
}

/// The voices a person can pick for read-aloud playback, and the Try button's sample.
///
/// A sample is ElevenLabs' own free preview, so trying costs nothing; pressing Try again while it
/// plays stops it, and a change of voice stops it too.
@MainActor
@Observable
public final class PlaybackVoicesStore {
    /// `nil` until the first answer.
    public private(set) var voices: PlaybackVoices?
    public private(set) var loadError: String?
    public private(set) var sampleState: VoiceSampleState = .idle
    /// The refusal or failure of the last Try, shown beside the button.
    public private(set) var sampleError: String?

    /// Set by the app once, before the Settings screen can open.
    @ObservationIgnored public var player: (any VoiceSamplePlayer)? {
        didSet { player?.onFinished = { [weak self] in self?.sampleFinished() } }
    }

    @ObservationIgnored private let api: any PlaybackVoicesApiClient
    /// Bumped by every Try and stop; an answer that finds it moved is stale and dropped.
    @ObservationIgnored private var epoch = 0

    public init(api: any PlaybackVoicesApiClient) {
        self.api = api
    }

    public func load() async {
        do {
            voices = try await api.getPlaybackVoices()
            loadError = nil
        } catch {
            loadError = (error as? PaiError)?.userMessage ?? "Could not load the voices"
        }
    }

    /// Plays the sample of `voiceId`, or stops the one playing. `nil` is the default voice.
    public func tryVoice(_ voiceId: String?) async {
        if sampleState != .idle {
            stopSample()
            return
        }
        guard let id = (voiceId?.isEmpty == false ? voiceId : nil) ?? voices?.defaultVoiceId else { return }
        epoch += 1
        let mine = epoch
        sampleState = .loading
        sampleError = nil
        do {
            let data = try await api.fetchPlaybackVoiceSample(provider: .elevenlabs, voiceId: id)
            guard mine == epoch else { return }
            guard let player else { throw PaiError.transport("There is no speaker for the sample.") }
            try player.play(data)
            sampleState = .playing
        } catch {
            guard mine == epoch else { return }
            sampleState = .idle
            sampleError = Self.message(of: error)
        }
    }

    public func stopSample() {
        epoch += 1
        player?.stop()
        sampleState = .idle
    }

    private func sampleFinished() {
        sampleState = .idle
    }

    private static func message(of error: Error) -> String {
        if let refusal = error as? PlaybackRefusal { return refusal.message }
        if let paiError = error as? PaiError { return paiError.userMessage }
        return "The sample could not be played."
    }
}
