import AVFoundation

/// Captures mono PCM from the microphone and hands it to whoever is listening — the one piece of
/// `VoiceRecordingSession`'s contract the package cannot supply itself
/// (`PAIKit/Stores/Voice/VoiceRecordingSession.swift`: "left for the app — microphone capture and
/// `AVAudioSession` interruption observation").
///
/// Not an actor and not `@MainActor`. `AVAudioEngine`'s tap block runs on a real-time audio
/// thread, where neither actor kind may be entered, so this type is a plain, self-contained class
/// whose callbacks fire on that thread. A caller that needs to touch `@MainActor` state from a
/// callback (`VoiceRecordingSession.ingestAudioChunk` is `@MainActor`) must hop off itself first —
/// exactly what that method's own documentation requires, and what `VoiceRecorderController` does.
final class MicrophoneCapture: @unchecked Sendable {
    enum CaptureError: Error {
        case formatUnavailable
        case converterUnavailable
    }

    /// One buffer of mono, 16-bit little-endian PCM at the rate `start(targetSampleRate:)` was
    /// given — already resampled and format-converted, matching `ingestAudioChunk`'s contract
    /// that it never resamples on its own.
    var onChunk: (@Sendable ([Int16]) -> Void)?
    /// The same buffer, unconverted, as mono 16-bit PCM at the hardware's own rate — what a saved
    /// recording's "raw" half is built from, since the batch re-transcription endpoint accepts
    /// any rate and the whole point of keeping it is to have something the realtime path's
    /// resampling cannot have degraded.
    var onRawChunk: (@Sendable ([Int16]) -> Void)?
    /// One RMS reading per buffer, normalised to `0...1` — what `VoiceRecordingSession.ingestLevel`
    /// and the recording's own level metering both want, computed once here rather than twice.
    var onLevel: (@Sendable (Double) -> Void)?

    private let engine = AVAudioEngine()
    private var sendConverter: AVAudioConverter?
    private var rawConverter: AVAudioConverter?
    private var sendFormat: AVAudioFormat?
    private var rawFormat: AVAudioFormat?

    /// The input's own rate before any conversion — what `VoiceAudioRatePolicy.transportRate`
    /// must be given to decide the rate actually negotiated for `start(targetSampleRate:)`.
    var hardwareSampleRate: Int {
        Int(engine.inputNode.inputFormat(forBus: 0).sampleRate)
    }

    /// `targetSampleRate` should already be `VoiceAudioRatePolicy.transportRate(hardwareRate:)` —
    /// this type does no rate policy of its own, only the conversion the policy decided on.
    func start(targetSampleRate: Int) throws {
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        guard
            let sendFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: Double(targetSampleRate), channels: 1, interleaved: true
            ),
            let rawFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: inputFormat.sampleRate, channels: 1, interleaved: true
            )
        else { throw CaptureError.formatUnavailable }
        guard
            let sendConverter = AVAudioConverter(from: inputFormat, to: sendFormat),
            let rawConverter = AVAudioConverter(from: inputFormat, to: rawFormat)
        else { throw CaptureError.converterUnavailable }

        self.sendFormat = sendFormat
        self.rawFormat = rawFormat
        self.sendConverter = sendConverter
        self.rawConverter = rawConverter

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        sendConverter = nil
        rawConverter = nil
        sendFormat = nil
        rawFormat = nil
    }

    /// Runs on the tap's real-time thread. `AVAudioConverter.convert` allocates internally, which
    /// is not real-time-safe in the strict sense — accepted here because the tap buffer is
    /// generous (2048 frames, tens of milliseconds at any of the rates this app negotiates) and
    /// this is a phone microphone feed rather than a synthesizer voice; moving the conversion to
    /// another thread would only relocate the same work, not remove it.
    private func process(_ buffer: AVAudioPCMBuffer) {
        onLevel?(Self.rms(of: buffer))
        if let sendFormat, let sendConverter, let samples = Self.convert(buffer, using: sendConverter, to: sendFormat) {
            onChunk?(samples)
        }
        if let rawFormat, let rawConverter, let samples = Self.convert(buffer, using: rawConverter, to: rawFormat) {
            onRawChunk?(samples)
        }
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

    /// Root-mean-square over the buffer's first channel, normalised to `0...1` the way
    /// `SilenceDetector` expects — matching the web's `calculateRms` reading time-domain samples
    /// as a plain magnitude rather than decibels.
    private static func rms(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        let samples = channelData[0]
        var sum: Double = 0
        for index in 0..<frameLength {
            let sample = Double(samples[index])
            sum += sample * sample
        }
        return (sum / Double(frameLength)).squareRoot()
    }
}
