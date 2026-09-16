import AVFoundation
import Foundation

/// Plays back ElevenLabs' `pcm_24000` TTS audio — the one piece of `SpeechOutputSession`'s
/// contract (`PAIKit`) this package cannot supply itself, mirroring `MicrophoneCapture`'s own
/// split for the input side: everything about *when* to speak and *what* lives in the testable
/// package, and this type only turns already-decoded samples into sound and reports back once
/// they have actually finished being heard.
///
/// Not attached to an `AVAudioEngine` of its own. The design calls for one engine serving both
/// capture and playback — VPIO's echo cancellation needs to see what the phone is actually
/// playing to cancel it out of the microphone's own input — so `attach(to:mixer:)` connects this
/// instance's nodes into whichever engine the caller already owns (`MicrophoneCapture`'s, in the
/// running app) rather than creating a second one. Until `attach(to:mixer:)` runs,
/// `schedule(messageId:samples:)` is a harmless no-op instead of a crash, so this type is safe to
/// construct before the engine it will eventually join exists.
final class SpeechOutput: @unchecked Sendable {
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var format: AVAudioFormat?

    /// Fires once the last buffer scheduled for a reply (via `markComplete(messageId:)`) has
    /// actually finished being heard — not when it was merely scheduled, which a live socket
    /// probe showed can be seconds to minutes earlier than when a reply is truly done playing.
    /// Called on whatever thread `AVAudioPlayerNode`'s own completion callback runs on, never the
    /// main actor — the caller must hop itself, the same contract `MicrophoneCapture`'s callbacks
    /// already have for the input side.
    var onFinishedPlaying: (@Sendable (Int) -> Void)?

    /// `AVAudioUnitTimePitch.rate` — free, unbounded, adjustable mid-playback. ElevenLabs'
    /// `voice_settings.speed` is deliberately left at its default instead; see
    /// `VoiceTtsProtocol.voiceSettingsSpeed`'s own doc comment for why speeding up happens here
    /// and not on the wire.
    var speed: Float {
        get { timePitch.rate }
        set { timePitch.rate = newValue }
    }

    init() {}

    /// Attaches this instance's nodes into `engine`, connected ahead of `mixer`.
    ///
    /// 🚨 Ordering matters for `setVoiceProcessingEnabled(true)`'s echo reference: the playback
    /// graph must already be attached and connected before voice processing is enabled on the
    /// engine's IO nodes, or AEC silently has nothing to cancel against — a field report the
    /// earlier design report leans on for exactly this trap. Call this before enabling voice
    /// processing on `engine`, never after.
    func attach(to engine: AVAudioEngine, mixer: AVAudioMixerNode) {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)
        else { return }
        self.format = format
        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.connect(playerNode, to: timePitch, format: format)
        engine.connect(timePitch, to: mixer, format: format)
    }

    /// One chunk of normalised (`-1...1`) mono samples at 24kHz, for `messageId`'s reply —
    /// `SpeechOutputDependencies.playAudio`'s production implementation. `AVAudioPlayerNode`
    /// queues scheduled buffers in the order they arrive, so chunks handed over in wire order
    /// play in wire order with no gap-filling logic needed here. `messageId` itself is not
    /// attached to the buffer — `markComplete(messageId:)` is what actually reports playback
    /// finishing, since a plain buffer carries no identity of its own.
    func schedule(messageId: Int, samples: [Float]) {
        guard let format, !samples.isEmpty,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() { channel[0][index] = sample }

        if !playerNode.isPlaying { playerNode.play() }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// No more audio is coming for `messageId` — `SpeechOutputDependencies.markReplyAudioComplete`'s
    /// production implementation. Every real chunk for `messageId` has already been scheduled by
    /// the time this runs, so there is no buffer left to retroactively attach a completion handler
    /// to; instead this schedules one silent, effectively inaudible marker buffer of its own,
    /// `.dataPlayedBack`-complete only once everything scheduled ahead of it — the whole reply —
    /// has actually been rendered through the audio device, not merely handed to the player.
    func markComplete(messageId: Int) {
        guard let format,
            let marker = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1),
            let channel = marker.floatChannelData
        else {
            onFinishedPlaying?(messageId)
            return
        }
        marker.frameLength = 1
        channel[0][0] = 0

        if !playerNode.isPlaying { playerNode.play() }
        playerNode.scheduleBuffer(marker, at: nil, options: [], completionCallbackType: .dataPlayedBack) {
            [weak self] _ in
            self?.onFinishedPlaying?(messageId)
        }
    }

    /// "computer skip"'s audible half, and what a dropped TTS connection needs before resuming on
    /// a fresh context — stops immediately and drops every buffer scheduled but not yet heard,
    /// rather than letting whatever is already queued keep playing.
    ///
    /// Whether `AVAudioPlayerNode.stop()` invokes the marker buffer's completion handler for a
    /// reply it cuts off is not documented either way — only device testing would answer that.
    /// It does not matter here: `onFinishedPlaying` calling back into a `messageId` the session
    /// no longer considers current is already a guarded no-op on the `SpeechOutputSession` side
    /// (`playbackFinished(messageId:)` only acts when `messageId` is still the one playing), so a
    /// stray callback after a skip is silently ignored either way.
    func stop() {
        playerNode.stop()
    }
}
