import AVFoundation
import PAIKit
import Speech

/// Feeds converted microphone audio into Apple's on-device `SpeechAnalyzer`/`DictationTranscriber`
/// and turns its results into `CommandObservation`s for `CommandDetector` — the offline half of
/// the command channel, so "Kai stop" works even with the transcription socket down, which is
/// the exact situation this channel exists for. Idle listening is free and fully offline: nothing
/// here ever opens a network connection except the one-time, explicit model download in
/// `installAssets(locale:)`.
///
/// Fed the same converted PCM `MicrophoneCapture.onChunk` already delivers (mono 16-bit at the
/// negotiated transport rate) — a second, independent consumer of the same tap output, not a
/// second tap on the input node: a `SpeechAnalyzer` "can only analyze one input sequence at a
/// time", but this app already converts the hardware buffer once for the realtime socket and can
/// hand the analyzer that same buffer.
///
/// 🚨 Unverified: this file compiles nowhere but a macOS run — see the repository's own note on
/// everything under `PAI/`. The `Speech` framework surface here (iOS 26) was read from Apple's
/// documentation rather than exercised against a real compiler; word-level timing
/// (`CommandObservation.wordTimes`) is deliberately left `nil` for now rather than guessed at
/// from `AttributedString`'s time-range attributes — `CommandDetector`'s pause gate already
/// degrades gracefully without it, and getting the run's actual attribute shape right is safer
/// done against a device than guessed from documentation.
@MainActor
final class OnDeviceCommandListener {
    var onObservation: ((CommandObservation) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var transcriber: DictationTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var sampleRate: Double = 16_000
    private var takeOffset = 0

    /// `locale` should already be derived from the STT language setting (`de-DE`/`en-US`) by the
    /// caller — this type does no language mapping of its own. `phrases` seeds the contextual
    /// strings the model is biased toward: every configured command phrase and its built-in
    /// variants, so the wake words are recognized more reliably than ordinary dictation
    /// vocabulary would be on their own.
    func start(locale: Locale, phrases: [String], sampleRate: Double) throws {
        stop()
        self.sampleRate = sampleRate

        let transcriber = DictationTranscriber(
            locale: locale, contentHints: [.farField], transcriptionOptions: [],
            reportingOptions: [.volatileResults], attributeOptions: [])
        self.transcriber = transcriber

        // `SpeechDetector` gates transcription by the presence of voice, saving power while the
        // channel is idle — exactly the "free and offline" idle-listening requirement.
        let detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: false)

        var context = AnalysisContext()
        context.contextualStrings = [AnalysisContext.ContextualStringsTag("commands"): phrases]

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        analyzer = SpeechAnalyzer(inputSequence: stream, modules: [detector, transcriber], analysisContext: context)

        resultsTask = Task { [weak self] in
            guard let results = self?.transcriber?.results else { return }
            do {
                for try await result in results {
                    await self?.handle(result)
                }
            } catch {
                // A thrown error ends the stream the same way a deliberate `stop()` does —
                // nothing further to report either way; `stop()` is the only way this listener
                // is meant to end, so a stream failure here is not distinguished from that.
            }
        }
    }

    /// `pcm16le` — the same converted buffer `MicrophoneCapture.onChunk` delivers, never
    /// resampled again here. `atOffset` is this chunk's position in the take, in samples,
    /// matching every other pipeline type's addressing — recorded so the next observation this
    /// listener reports carries it.
    func ingest(pcm16le: [Int16], atOffset: Int) {
        takeOffset = atOffset
        guard let inputContinuation,
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm16le.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(pcm16le.count)
        guard let channelData = buffer.int16ChannelData else { return }
        pcm16le.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channelData[0].update(from: base, count: pcm16le.count)
        }
        inputContinuation.yield(AnalyzerInput(buffer: buffer))
    }

    func stop() {
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
    }

    private func handle(_ result: DictationTranscriber.Result) {
        let text = String(result.text.characters)
        guard !text.isEmpty else { return }
        onObservation?(CommandObservation(text: text, isFinal: result.isFinal, wordTimes: nil, atOffset: takeOffset))
    }
}

extension OnDeviceCommandListener {
    /// Whether the on-device model this listener needs is already downloaded. `AssetInventory`
    /// tracks model installation per module and shares it across every app that uses the same
    /// locale, so this can read "already installed" for a phrase-gate model iOS itself shipped.
    static func assetsInstalled(locale: Locale) async -> Bool {
        let probe = DictationTranscriber(locale: locale, contentHints: [])
        let status = await AssetInventory.status(forModules: [probe])
        return status == .installed
    }

    /// Downloads the model. Needs network, so this is a settings action Freddy takes at home —
    /// `AssetInventory.assetInstallationRequest` "downloads the model on first use and needs
    /// network then", and a call is never the moment to discover that.
    static func installAssets(locale: Locale) async throws {
        let probe = DictationTranscriber(locale: locale, contentHints: [])
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) else { return }
        try await request.downloadAndInstall()
    }
}
