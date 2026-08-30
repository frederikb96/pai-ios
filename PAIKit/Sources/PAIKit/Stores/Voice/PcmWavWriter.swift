import Foundation

/// Wraps raw 16-bit little-endian mono PCM in a minimal WAV container — what the batch
/// re-transcription endpoint and the "attach as file" action both need, and what
/// `RecordingAudioStorage` stores. Mirrors the web's `wrapPcmAsWav`: no compression, no extra
/// chunks, just the 44-byte canonical header in front of the samples.
///
/// Pure `Foundation`, no Apple-only import — despite writing bytes for an app-target feature,
/// this belongs in the package rather than `PAI/`, the same reasoning `CLAUDE.md`'s *Layers*
/// section states for everything here: what needs no Apple framework is proven on Linux for
/// free, and only *where* the bytes land on disk is a real-device concern.
public enum PcmWavWriter {
    public static func wrap(pcm16le samples: [Int16], sampleRate: Int) -> Data {
        var data = header(sampleRate: sampleRate, dataSize: UInt32(samples.count * 2))
        data.reserveCapacity(44 + samples.count * 2)
        for sample in samples {
            data.appendLE(UInt16(bitPattern: sample))
        }
        return data
    }

    /// The 44-byte canonical header alone, for a caller building the file incrementally
    /// (`IncrementalWavWriter`) rather than from one complete sample array.
    static func header(sampleRate: Int, dataSize: UInt32) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var data = Data(capacity: 44)
        data.append(contentsOf: "RIFF".utf8)
        data.appendLE(UInt32(36) + dataSize)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.appendLE(UInt32(16))  // PCM fmt chunk size
        data.appendLE(UInt16(1))  // PCM format tag
        data.appendLE(channels)
        data.appendLE(UInt32(sampleRate))
        data.appendLE(byteRate)
        data.appendLE(blockAlign)
        data.appendLE(bitsPerSample)
        data.append(contentsOf: "data".utf8)
        data.appendLE(dataSize)
        return data
    }
}

extension Data {
    fileprivate mutating func appendLE(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
    fileprivate mutating func appendLE(_ value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

/// Builds the same WAV format as `PcmWavWriter.wrap`, but in pieces a caller appends to a file as
/// audio is captured — the fix for the take that used to live entirely in memory until the very
/// end: killed at minute 55, nothing before it was saved either. `finalHeader` doubles as both
/// the true end-of-take header and a header a caller can re-write over the placeholder after
/// every append, so a file caught mid-write by a process death already has a correct size for
/// everything appended so far rather than a placeholder claiming zero bytes of audio.
///
/// Pure byte computation only — no file handle, no path. `StreamingRecordingFile` is what
/// actually writes these to disk.
public struct IncrementalWavWriter: Sendable {
    public let sampleRate: Int

    public init(sampleRate: Int) {
        self.sampleRate = sampleRate
    }

    /// Written once, before any audio — `finalHeader` is what overwrites this in place once the
    /// real size is known (or known-so-far).
    public func placeholderHeader() -> Data {
        PcmWavWriter.header(sampleRate: sampleRate, dataSize: 0)
    }

    /// The bytes for one buffer of samples — append directly to the open file, after `data`.
    public func frame(pcm16le samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            data.appendLE(UInt16(bitPattern: sample))
        }
        return data
    }

    /// The header to write back at offset 0, reflecting everything appended so far.
    public func finalHeader(totalSampleCount: Int) -> Data {
        PcmWavWriter.header(sampleRate: sampleRate, dataSize: UInt32(totalSampleCount * 2))
    }
}
