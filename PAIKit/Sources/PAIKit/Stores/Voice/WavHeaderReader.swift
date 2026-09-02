import Foundation

/// Reads the two fields a take's own header already carries — `PcmWavWriter`'s canonical 44-byte
/// layout, rewritten after every `StreamingRecordingFile.append()` to declare the true length so
/// far (see that type's own doc comment). A startup reconciliation pass reads these back rather
/// than guessing a sample rate or deriving a duration from `Data.count`, because the file itself
/// is the only trustworthy record of what a take actually captured before whatever ended it.
public enum WavHeaderReader {
    public static let headerByteCount = 44

    /// `nil` for anything shorter than a full header, or missing the two four-byte tags a
    /// `PcmWavWriter` header always opens with — a truncated or foreign file, not a take of this
    /// app's own making.
    public static func parse(_ header: Data) -> (sampleRate: Int, dataSize: UInt32)? {
        guard header.count >= headerByteCount else { return nil }
        let bytes = [UInt8](header.prefix(headerByteCount))
        guard tag(bytes, at: 0) == "RIFF", tag(bytes, at: 8) == "WAVE" else { return nil }
        let sampleRate = Int(readLEUInt32(bytes, at: 24))
        let dataSize = readLEUInt32(bytes, at: 40)
        return (sampleRate, dataSize)
    }

    private static func tag(_ bytes: [UInt8], at offset: Int) -> String {
        String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
    }

    private static func readLEUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
