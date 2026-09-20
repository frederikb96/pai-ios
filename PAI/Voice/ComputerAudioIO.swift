@preconcurrency import AVFoundation
import PAIKit

/// Bidirectional audio for a live Computer conversation: captures the microphone AND plays
/// Computer's own synthesized speech back through the same engine — unlike `MicrophoneCapture`,
/// which only ever captures, because nothing else in this app has needed a downlink before.
///
/// `.voiceChat` mode is what enables the platform's own built-in acoustic echo cancellation —
/// dictation's `.measurement` mode (`VoiceRecorderController.configureAudioSession`) deliberately
/// disables exactly this kind of processing, which is right for a transcriber and wrong here,
/// where the speaker and the microphone are both live at once. Freddy's own instruction against
/// ANY app-level echo arbitration ("the transports Computer runs on all handle it in hardware",
/// `pai_cloud.computer.engine`'s own doc comment) is read here as "use the platform's hardware/OS
/// echo cancellation, never build a software one" — `.voiceChat` is the one lever this app's own
/// hardware actually offers for that.
///
/// Not an actor and not `@MainActor`, matching `MicrophoneCapture`: the tap block runs on a
/// real-time audio thread, where neither actor kind may be entered.
final class ComputerAudioIO: @unchecked Sendable {
    enum SetupError: Error {
        case formatUnavailable
        case converterUnavailable
    }

    /// One buffer of mono 16-bit PCM at `VoiceSocketProtocol.audioUplinkHz` — already resampled,
    /// same contract as `MicrophoneCapture.onChunk`.
    var onMicChunk: (@Sendable ([Int16]) -> Void)?
    /// Mirrors `MicrophoneCapture.onConfigurationChange` — a route change invalidates every tap
    /// and connection on the engine; nothing here restarts itself. Delivered on the main actor.
    var onConfigurationChange: (@Sendable () -> Void)?

    private let engine = AVAudioEngine()
    private let audioSession = AVAudioSession.sharedInstance()
    private var configurationObserver: NSObjectProtocol?
    private var micConverter: AVAudioConverter?
    private var micSendFormat: AVAudioFormat?
    private var playerNode: AVAudioPlayerNode?
    private let playbackFormat: AVAudioFormat?

    init() {
        playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: Double(VoiceSocketProtocol.audioDownlinkHz),
            channels: 1, interleaved: true
        )
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    /// Activates the session, wires the microphone tap, and readies the player — mirrors
    /// `MicrophoneCapture.start(targetSampleRate:)`'s shape, plus the downlink half it has no use
    /// for.
    func start() throws {
        try activateSession()

        let node = AVAudioPlayerNode()
        engine.attach(node)
        if let playbackFormat {
            engine.connect(node, to: engine.mainMixerNode, format: playbackFormat)
        }
        playerNode = node

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard
            let sendFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: Double(VoiceSocketProtocol.audioUplinkHz),
                channels: 1, interleaved: true
            )
        else { throw SetupError.formatUnavailable }
        guard let converter = AVAudioConverter(from: inputFormat, to: sendFormat) else {
            throw SetupError.converterUnavailable
        }
        micSendFormat = sendFormat
        micConverter = converter

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.processMic(buffer)
        }

        engine.prepare()
        try engine.start()
        node.play()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if let playerNode {
            engine.disconnectNodeOutput(playerNode)
            engine.detach(playerNode)
        }
        playerNode = nil
        if engine.isRunning { engine.stop() }
        micConverter = nil
        micSendFormat = nil
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// One chunk of Computer's own synthesized speech — mono 16-bit PCM at
    /// `VoiceSocketProtocol.audioDownlinkHz`, exactly the shape a downlink frame's payload
    /// already is (`VoiceSocketProtocol.unpackDownlinkAudio`). Buffers scheduled with no explicit
    /// time play back-to-back in the order scheduled, which is what keeps chunks in order without
    /// this type needing to interpret `ref` as a sequence number itself.
    ///
    /// `onFinished` fires once this chunk has genuinely finished rendering — the receipt
    /// `ComputerCallSession.notePlayed(ref:)` needs — never merely when it was scheduled. Called
    /// on whatever queue `AVAudioPlayerNode` itself calls back on, not necessarily the main actor.
    func play(pcm16le data: Data, onFinished: @escaping @Sendable () -> Void) {
        guard let playerNode, let playbackFormat else {
            onFinished()
            return
        }
        let sampleCount = data.count / 2
        guard sampleCount > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(sampleCount))
        else {
            onFinished()
            return
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        guard let channelData = buffer.int16ChannelData else {
            onFinished()
            return
        }
        // `loadUnaligned` rather than `bindMemory`: this payload is `data.suffix(from:)` off a
        // larger buffer (`VoiceSocketProtocol.unpackDownlinkAudio`), so it is not guaranteed to
        // be 2-byte aligned — binding misaligned memory to `Int16` is undefined behavior even
        // though it usually "works". `Int16(littleEndian:)` matches the wire format explicitly
        // rather than relying on every Apple target happening to be little-endian already.
        data.withUnsafeBytes { raw in
            for index in 0..<sampleCount {
                channelData[0][index] = Int16(
                    littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
            }
        }
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            onFinished()
        }
    }

    /// A barge-in: drop everything buffered for playback right now, without waiting for it to
    /// finish (`docs/VOICE_PROTOCOL.md`'s `clear`). `AVAudioPlayerNode.stop()` discards every
    /// scheduled buffer and stops the node outright, so playback must be restarted before
    /// anything scheduled after this call will ever render.
    func clearPlayback() {
        playerNode?.stop()
        playerNode?.play()
    }

    /// `.playAndRecord` + `.voiceChat`, active for the whole call — the same pairing dictation
    /// uses for `.measurement`, minus the earcon-specific reasoning that mode doesn't need here.
    /// `.defaultToSpeaker` keeps Computer audible with no headset connected; `.allowBluetooth`
    /// keeps a paired headset's own mic and speaker available.
    private func activateSession() throws {
        let options: AVAudioSession.CategoryOptions = [.allowBluetooth, .defaultToSpeaker]
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        try audioSession.setActive(true)
    }

    /// Runs on the tap's real-time thread — see `MicrophoneCapture.process(_:)`'s own doc comment
    /// for why `AVAudioConverter.convert` is accepted here despite allocating internally.
    private func processMic(_ buffer: AVAudioPCMBuffer) {
        guard let micSendFormat, let micConverter,
            let samples = Self.convert(buffer, using: micConverter, to: micSendFormat)
        else { return }
        onMicChunk?(samples)
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat)
        -> [Int16]?
    {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, let channelData = outBuffer.int16ChannelData else { return nil }

        let frameLength = Int(outBuffer.frameLength)
        guard frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }
}
