import Foundation

/// Addresses a take's audio in samples counted from the take's first captured sample — the unit
/// every pipeline type in this directory uses instead of wall-clock time or a connection's own
/// elapsed seconds, since a chunk's position in the take never depends on how many reconnects it
/// took to get there. A plain `Range<Int>` rather than a new nominal type: every operation the
/// pipeline needs on one (merging, clamping, overlap) is already `Range`'s own.
public typealias SampleRange = Range<Int>

/// A byte range inside a take's `-sent.wav` file — what `TakeAudioReader` actually seeks and
/// reads. Computed from a `SampleRange`: 16-bit mono PCM, so each sample is two bytes, offset
/// past the header whose length `StreamingRecordingFile` and `WavHeaderReader` already agree on.
public struct WavByteRange: Sendable, Equatable {
    public let offset: Int
    public let length: Int

    public init(offset: Int, length: Int) {
        self.offset = offset
        self.length = length
    }

    /// The one place sample offsets and file byte offsets are allowed to meet — everything else
    /// in the pipeline stays in samples.
    public static func forSamples(
        _ range: SampleRange, headerByteCount: Int = WavHeaderReader.headerByteCount
    ) -> WavByteRange {
        WavByteRange(offset: headerByteCount + range.lowerBound * 2, length: range.count * 2)
    }
}
