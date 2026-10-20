@preconcurrency import AVFoundation
import PAIKit

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

    /// One buffer of mono, 16-bit little-endian PCM at `VoiceSocketProtocol.audioUplinkHz` —
    /// the rate the voice socket declares, whatever the microphone's own rate is. Already
    /// converted, matching `ingestAudioChunk`'s contract that it never resamples on its own, with
    /// `DictationInputGain` applied, and the same samples the take's local recording stores.
    var onChunk: (@Sendable ([Int16]) -> Void)?
    /// One RMS reading per buffer, normalised to `0...1` and scaled by `DictationInputGain` like the samples — what `VoiceRecordingSession.ingestLevel`
    /// and the recording's own level metering both want, computed once here rather than twice.
    var onLevel: (@Sendable (Double) -> Void)?
    /// 🚨 The engine has stopped itself and every tap and connection on it is now invalid —
    /// `AVAudioEngine`'s documented behaviour on a configuration change, which a route change
    /// causes: a Bluetooth headset connecting, headphones going in, a call ending. Nothing
    /// restarts it, and nothing reports it: the tap simply never fires again, so a long recording
    /// dies mid-sentence and looks exactly like the app having been suspended. Whoever owns the
    /// take has to `stop()` and `start()` again in response. Delivered on the
    /// main actor.
    var onConfigurationChange: (@Sendable () -> Void)?

    private let engine = AVAudioEngine()
    private var configurationObserver: NSObjectProtocol?
    private var sendConverter: AVAudioConverter?
    private var sendFormat: AVAudioFormat?

    /// The input's own rate before any conversion — what the narrowband judgement reads.
    var hardwareSampleRate: Int {
        Int(engine.inputNode.inputFormat(forBus: 0).sampleRate)
    }

    init() {
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

    func start() throws {
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard
            AudioEngineReadiness.isUsableInputFormat(
                sampleRate: inputFormat.sampleRate, channelCount: Int(inputFormat.channelCount))
        else { throw CaptureError.formatUnavailable }

        guard
            let sendFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: Double(VoiceSocketProtocol.audioUplinkHz), channels: 1,
                interleaved: true
            )
        else { throw CaptureError.formatUnavailable }
        guard let sendConverter = AVAudioConverter(from: inputFormat, to: sendFormat) else {
            throw CaptureError.converterUnavailable
        }

        self.sendFormat = sendFormat
        self.sendConverter = sendConverter

        // `format: nil` taps whatever the input delivers. A route change between reading the
        // input format above and installing the tap would otherwise leave a tap format that
        // disagrees with the hardware, and `installTap` raises on that; `process` re-keys the
        // converter to each buffer's actual format instead.
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        sendConverter = nil
        sendFormat = nil
    }

    /// Runs on the tap's real-time thread. `AVAudioConverter.convert` allocates internally, which
    /// is not real-time-safe in the strict sense — accepted here because the tap buffer is
    /// generous (2048 frames, tens of milliseconds at any hardware rate) and
    /// this is a phone microphone feed rather than a synthesizer voice; moving the conversion to
    /// another thread would only relocate the same work, not remove it.
    private func process(_ buffer: AVAudioPCMBuffer) {
        onLevel?(DictationInputGain.apply(toLevel: Self.rms(of: buffer)))
        guard let sendFormat else { return }
        let converter: AVAudioConverter
        if let sendConverter, sendConverter.inputFormat == buffer.format {
            converter = sendConverter
        } else {
            guard let fresh = AVAudioConverter(from: buffer.format, to: sendFormat) else { return }
            sendConverter = fresh
            converter = fresh
        }
        if let samples = Self.convert(buffer, using: converter, to: sendFormat) {
            onChunk?(DictationInputGain.apply(to: samples))
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

    /// Root-mean-square over the buffer's first channel, normalised to `0...1` — what the level
    /// meter draws, and matching the web's `calculateRms` in reading time-domain samples as a
    /// plain magnitude rather than decibels.
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
