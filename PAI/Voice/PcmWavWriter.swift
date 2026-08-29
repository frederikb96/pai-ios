import Foundation

/// Wraps raw 16-bit little-endian mono PCM in a minimal WAV container — what the batch
/// re-transcription endpoint and the "attach as file" action both need, and what
/// `RecordingAudioStorage` stores. Mirrors the web's `wrapPcmAsWav`: no compression, no extra
/// chunks, just the 44-byte canonical header in front of the samples.
enum PcmWavWriter {
    static func wrap(pcm16le samples: [Int16], sampleRate: Int) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * 2)

        var data = Data(capacity: 44 + Int(dataSize))
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
        for sample in samples {
            data.appendLE(UInt16(bitPattern: sample))
        }
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
