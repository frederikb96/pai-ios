import Foundation

/// A WAV file written incrementally as audio is captured, rather than assembled in memory and
/// written once at the end. Only `FileHandle`/`URL` — nothing Apple-only — so this is proven on
/// Linux; `PAI/`'s `FileRecordingAudioStorage` contributes only the sandboxed path this opens.
///
/// The header at byte 0 is rewritten after every `append`, not only in `finalize()`: a process
/// killed mid-take leaves a file whose header already matches every sample actually written, not
/// a placeholder claiming zero bytes of audio. That is the entire point of this type — a take
/// that lived only in memory until `stop()` is exactly the bug this replaces.
public final class StreamingRecordingFile: @unchecked Sendable {
    private let writer: IncrementalWavWriter
    private var handle: FileHandle?
    public private(set) var sampleCount = 0

    /// How much audio a sudden power loss may cost, expressed as a sample count.
    ///
    /// The header repatch above already survives the *process* dying, because bytes handed to
    /// the OS outlive the program that wrote them. It does not survive the *machine* going
    /// down, and a phone running flat during an hour of recording in a pocket is the same
    /// scenario this type exists for. Flushing on every buffer would spend disk and battery
    /// continuously to close a rare gap; flushing on a cadence bounds the loss instead.
    private let syncEverySamples: Int
    private var samplesSinceSync = 0

    /// A seam, because `synchronize()` has no observable effect: without it the cadence rule
    /// could be written wrong and no test could tell.
    var syncHandler: (FileHandle) -> Void = { try? $0.synchronize() }

    /// `nil` when the file could not even be created — a caller treats that the same as any
    /// other disk failure: the take keeps running, this half of it is simply not being saved.
    public init?(
        url: URL, sampleRate: Int, syncIntervalSeconds: Int = 30, fileManager: FileManager = .default
    ) {
        writer = IncrementalWavWriter(sampleRate: sampleRate)
        syncEverySamples = max(1, sampleRate * syncIntervalSeconds)
        guard fileManager.createFile(atPath: url.path, contents: writer.placeholderHeader()),
            let handle = try? FileHandle(forWritingTo: url)
        else { return nil }
        self.handle = handle
    }

    public var hasData: Bool { sampleCount > 0 }

    /// Appends one buffer and repatches the header to match. A write failure closes the handle
    /// rather than leaving it to fail identically on every subsequent call — the take carries on
    /// either way, this file is just no longer being written to.
    public func append(pcm16le samples: [Int16]) {
        guard let handle, !samples.isEmpty else { return }
        guard (try? handle.seekToEnd()) != nil, (try? handle.write(contentsOf: writer.frame(pcm16le: samples))) != nil
        else {
            self.handle = nil
            return
        }
        sampleCount += samples.count
        repatchHeader(handle)

        samplesSinceSync += samples.count
        if samplesSinceSync >= syncEverySamples {
            samplesSinceSync = 0
            syncHandler(handle)
        }
    }

    private func repatchHeader(_ handle: FileHandle) {
        guard (try? handle.seek(toOffset: 0)) != nil,
            (try? handle.write(contentsOf: writer.finalHeader(totalSampleCount: sampleCount))) != nil
        else {
            self.handle = nil
            return
        }
    }

    /// Idempotent, and safe never to call at all — every `append` already left the header
    /// correct. This only closes the handle so nothing keeps the file open past the take.
    public func finalize() {
        guard let handle else { return }
        syncHandler(handle)
        try? handle.close()
        self.handle = nil
    }
}
