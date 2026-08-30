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
}
