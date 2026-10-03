import Foundation

/// Re-transcribes a whole past recording through the backend's batch route, in pieces small
/// enough that one upload never outlives a proxy's read timeout however long the recording is.
///
/// Each piece overlaps the previous one by a second, so a word cut at a piece boundary is heard
/// whole in one of the two; the backend removes the repeat itself (`previous_text` on
/// `POST /api/voice/takes/{take_id}/audio`), so the client only joins what comes back.
public enum RecordingRetranscription {
    public static let pieceSeconds = 300
    public static let overlapSeconds = 1
    /// How much of the text so far each piece carries as `previous_text`.
    public static let previousTextCharacters = 200

    /// The sample ranges to upload, in order.
    public static func pieces(totalSamples: Int, sampleRate: Int) -> [SampleRange] {
        guard totalSamples > 0, sampleRate > 0 else { return [] }
        let pieceSamples = pieceSeconds * sampleRate
        let overlapSamples = overlapSeconds * sampleRate
        var ranges: [SampleRange] = []
        var start = 0
        while true {
            let end = min(start + pieceSamples, totalSamples)
            ranges.append(start..<end)
            if end == totalSamples { return ranges }
            start = end - overlapSamples
        }
    }

    /// `read` returns a piece's samples; `transcribe` posts one WAV with the text so far and
    /// returns that piece's text, already stripped of what overlapped it.
    public static func run(
        totalSamples: Int, sampleRate: Int,
        read: @Sendable (SampleRange) async throws -> [Int16],
        transcribe: @Sendable (_ wav: Data, _ previousText: String?) async throws -> String
    ) async throws -> String {
        var text = ""
        for piece in pieces(totalSamples: totalSamples, sampleRate: sampleRate) {
            let samples = try await read(piece)
            let wav = PcmWavWriter.wrap(pcm16le: samples, sampleRate: sampleRate)
            let previous = text.isEmpty ? nil : String(text.suffix(previousTextCharacters))
            let pieceText = try await transcribe(wav, previous).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pieceText.isEmpty else { continue }
            text = text.isEmpty ? pieceText : "\(text) \(pieceText)"
        }
        return text
    }
}
