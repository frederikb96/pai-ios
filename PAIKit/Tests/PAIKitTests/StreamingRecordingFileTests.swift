import XCTest

@testable import PAIKit

/// The property under test throughout this file is durability, not just correctness: a file this
/// type produced must describe exactly what has actually reached disk at any moment, not only
/// once `finalize()` runs — that is the entire reason `StreamingRecordingFile` exists instead of
/// the array-in-memory-until-the-end approach it replaces.
final class StreamingRecordingFileTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("streaming-wav-test-\(UUID()).wav")
    }

    /// Reads the four bytes at a WAV file's `data` chunk size field (offset 40) — a black-box
    /// read of what a real player would see, independent of whichever internal formula produced
    /// it, so this cannot pass merely by echoing `IncrementalWavWriter`'s own arithmetic back at
    /// itself.
    private func declaredDataSize(at url: URL) throws -> UInt32 {
        let data = try Data(contentsOf: url)
        let bytes = [UInt8](data[40..<44])
        return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
    }

    func testFinalizeMatchesPcmWavWriterByteForByte() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let samples: [Int16] = [1, -1, 32767, -32768, 0, 1234, -1234]

        let file = try XCTUnwrap(StreamingRecordingFile(url: url, sampleRate: 24000))
        // Appended in three separate calls — exactly what a real capture callback does, one
        // buffer at a time, rather than one array handed over whole.
        file.append(pcm16le: Array(samples[0..<2]))
        file.append(pcm16le: Array(samples[2..<5]))
        file.append(pcm16le: Array(samples[5..<7]))
        file.finalize()

        let streamed = try Data(contentsOf: url)
        let wrapped = PcmWavWriter.wrap(pcm16le: samples, sampleRate: 24000)
        XCTAssertEqual(streamed, wrapped)
    }

    /// The crash-survivability property itself: never call `finalize()` — simulating a process
    /// death mid-take — and check the file left behind is still self-describing rather than a
    /// placeholder claiming zero bytes of audio while actually holding some.
    func testHeaderReflectsEveryAppendEvenWithoutFinalize() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try XCTUnwrap(StreamingRecordingFile(url: url, sampleRate: 16000))

        file.append(pcm16le: [1, 2, 3, 4, 5])
        XCTAssertEqual(try declaredDataSize(at: url), 10)

        file.append(pcm16le: [6, 7])
        XCTAssertEqual(try declaredDataSize(at: url), 14, "the header must already reflect this second append")

        // No finalize() — the "process died here" case.
        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(onDisk.count, 44 + 14, "every appended byte is on disk despite no finalize")
    }

    func testFinalizeIsIdempotentAndSafeToCallWithoutEverAppending() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try XCTUnwrap(StreamingRecordingFile(url: url, sampleRate: 24000))

        file.finalize()
        file.finalize()  // must not crash or corrupt anything the second time

        XCTAssertEqual(try declaredDataSize(at: url), 0)
        XCTAssertFalse(file.hasData)
    }

    func testAppendingAnEmptyBufferDoesNotAdvanceSampleCount() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try XCTUnwrap(StreamingRecordingFile(url: url, sampleRate: 24000))

        file.append(pcm16le: [])

        XCTAssertFalse(file.hasData)
        XCTAssertEqual(try declaredDataSize(at: url), 0)
    }

    func testInitFailsRatherThanCrashingWhenTheDirectoryDoesNotExist() {
        let url = URL(fileURLWithPath: "/nonexistent-directory-\(UUID())/take.wav")
        XCTAssertNil(StreamingRecordingFile(url: url, sampleRate: 24000))
    }

    // MARK: - Flush cadence

    /// `synchronize()` bounds what a device losing power costs. The cadence is the part that can
    /// be wrong — too eager spends disk and battery for an hour, too lazy loses the tail — and it
    /// has no observable effect, so it is asserted through the injected handler.
    func testFlushesOnceTheIntervalOfAudioHasAccumulated() throws {
        let url = tempURL()
        let file = try XCTUnwrap(StreamingRecordingFile(url: url, sampleRate: 100, syncIntervalSeconds: 2))
        var flushes = 0
        file.syncHandler = { _ in flushes += 1 }

        // 199 samples at 100 Hz is one sample short of the two-second interval.
        file.append(pcm16le: [Int16](repeating: 1, count: 199))
        XCTAssertEqual(flushes, 0, "a flush before the interval elapsed would defeat the point of having one")

        file.append(pcm16le: [Int16](repeating: 1, count: 1))
        XCTAssertEqual(flushes, 1)

        // The discriminating case for the counter reset. A buffer far shorter than the interval,
        // arriving straight after a flush, must NOT flush: without the reset the accumulator
        // stays above the threshold forever and every subsequent buffer flushes, however small —
        // which is the cost this cadence exists to avoid, and it is invisible in any test whose
        // next buffer happens to be a full interval long.
        file.append(pcm16le: [Int16](repeating: 1, count: 1))
        XCTAssertEqual(flushes, 1, "a one-sample buffer after a flush must not trigger another")

        file.append(pcm16le: [Int16](repeating: 1, count: 199))
        XCTAssertEqual(flushes, 2, "and the next full interval must")

        file.finalize()
        XCTAssertEqual(flushes, 3, "the last partial interval is exactly the audio a crash would otherwise cost")
    }

    /// A buffer far larger than the interval is one flush, not one per interval it spans.
    func testAnOversizedBufferFlushesOnce() throws {
        let url = tempURL()
        let file = try XCTUnwrap(StreamingRecordingFile(url: url, sampleRate: 100, syncIntervalSeconds: 1))
        var flushes = 0
        file.syncHandler = { _ in flushes += 1 }

        file.append(pcm16le: [Int16](repeating: 1, count: 1000))
        XCTAssertEqual(flushes, 1)
    }

}
