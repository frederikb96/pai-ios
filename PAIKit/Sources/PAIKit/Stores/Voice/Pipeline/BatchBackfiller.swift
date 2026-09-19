import Foundation

/// Executes one `BackfillPlanner.Request`: reads its audio range off the take's own sent file,
/// wraps it as a WAV, posts it to the batch endpoint with word timestamps, and produces the
/// `.batch` `Segment` the ledger should record — or the failure `BackfillPlanner.recordFailure`
/// needs to update the gap's attempt count.
public enum BatchBackfiller {
    public enum Outcome: Sendable, Equatable {
        case segment(Segment)
        /// The request's audio decoded to no speech at all — not a failure to retry, the same
        /// distinction `VoiceBatchTranscriber.Result.noSpeechDetected` already draws. The caller
        /// still needs to mark the gap as attempted, or a silent stretch would be retried forever.
        case noSpeechDetected
        case failed(String)
    }

    /// `transcribe` is the batch-transcribe closure's shape — bytes in at offset
    /// zero, words out at offset zero, take-relative shifting is this function's own job (it is
    /// the only caller that knows the request's start offset).
    public static func run(
        _ request: BackfillPlanner.Request, sampleRate: Int, language: VoiceSettings.Language,
        audioReader: any TakeAudioReader, takeId: String,
        transcribe: @Sendable (Data, VoiceSettings.Language) async throws -> (text: String, words: [Word])
    ) async -> Outcome {
        let byteRange = WavByteRange.forSamples(request.audioRange)
        let pcm: Data
        do {
            pcm = try await audioReader.readSamples(id: takeId, range: byteRange)
        } catch {
            return .failed("\(error)")
        }
        guard !pcm.isEmpty else { return .failed("no audio available for the requested range") }

        let samples = Self.pcm16le(from: pcm)
        let wav = PcmWavWriter.wrap(pcm16le: samples, sampleRate: sampleRate)

        let result: (text: String, words: [Word])
        do {
            result = try await transcribe(wav, language)
        } catch {
            return .failed("\(error)")
        }
        guard !result.text.isEmpty else { return .noSpeechDetected }

        // Words come back relative to the request's own audio (offset zero); shift them to
        // take-absolute offsets by the request's own start.
        let shiftedWords = result.words.map { word in
            Word(
                range: (word.range.lowerBound + request.audioRange.lowerBound)..<(word.range.upperBound
                    + request.audioRange.lowerBound),
                text: word.text, logprob: word.logprob
            )
        }
        // `SeamMerge` places each word by its own range, not by the segment's declared range, so
        // the segment's range is set to the gap's own un-margined `request.range` — the audio
        // margin exists only to give the model context, never to claim samples the gap itself
        // did not own.
        return .segment(Segment(range: request.range, text: result.text, words: shiftedWords, source: .batch))
    }

    /// The 16-bit little-endian samples `PcmWavWriter` needs, from what `TakeAudioReader` handed
    /// back as raw bytes.
    private static func pcm16le(from data: Data) -> [Int16] {
        let bytes = [UInt8](data)
        var samples: [Int16] = []
        samples.reserveCapacity(bytes.count / 2)
        var index = 0
        while index + 1 < bytes.count {
            let littleEndian = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
            samples.append(Int16(bitPattern: littleEndian))
            index += 2
        }
        return samples
    }
}
