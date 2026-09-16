import XCTest

@testable import PAIKit

final class SessionTimelineTests: XCTestCase {

    private let sampleRate = 16000  // 16000 samples/second — 1 sample = 0.0000625s

    func testAWordWithinTheFirstChunkMapsDirectlyToTakeOffsets() {
        var timeline = SessionTimeline()
        // The take had already captured 48000 samples before this connection's first chunk.
        timeline.recordTransmittedChunk(sessionSampleStart: 0, takeOffset: 48000, sampleCount: 16000)

        let range = timeline.takeRange(startSeconds: 0.0, endSeconds: 0.5, sampleRate: sampleRate)
        XCTAssertEqual(range, 48000..<56000)
    }

    /// The scenario the design exists for: a withheld silence-gate stretch never reached the
    /// socket at all, so the take offset jumps ahead of what the connection's own sample count
    /// would suggest — this is exactly what per-chunk bookkeeping (rather than a single linear
    /// offset) is for.
    func testATakeOffsetGapFromAWithheldGateStretchIsPreserved() {
        var timeline = SessionTimeline()
        timeline.recordTransmittedChunk(sessionSampleStart: 0, takeOffset: 0, sampleCount: 8000)
        // A silence gate withheld 32000 take samples that never reached the socket at all — the
        // next transmitted chunk's own session-relative start continues from 8000, but its take
        // offset jumps to 40000.
        timeline.recordTransmittedChunk(sessionSampleStart: 8000, takeOffset: 40000, sampleCount: 8000)

        // A word entirely inside the second chunk (session seconds 0.5..0.75).
        let range = timeline.takeRange(startSeconds: 0.5, endSeconds: 0.75, sampleRate: sampleRate)
        XCTAssertEqual(range, 40000..<44000)
    }

    /// Sized so one sample of the word sits exactly on the boundary between two recorded chunks —
    /// the lookup must not silently misplace it into the wrong chunk's offset.
    func testAWordCrossingExactlyOnAChunkBoundaryIsPlacedCorrectly() {
        var timeline = SessionTimeline()
        timeline.recordTransmittedChunk(sessionSampleStart: 0, takeOffset: 100_000, sampleCount: 1600)  // 0..<0.1s
        timeline.recordTransmittedChunk(sessionSampleStart: 1600, takeOffset: 101_600, sampleCount: 1600)  // 0.1..<0.2s

        // A word ending exactly at the boundary (0.1s == sample 1600).
        let endsAtBoundary = timeline.takeRange(startSeconds: 0.05, endSeconds: 0.1, sampleRate: sampleRate)
        XCTAssertEqual(endsAtBoundary, 100_800..<101_600)

        // A word starting exactly at the boundary.
        let startsAtBoundary = timeline.takeRange(startSeconds: 0.1, endSeconds: 0.15, sampleRate: sampleRate)
        XCTAssertEqual(startsAtBoundary, 101_600..<102_400)
    }

    /// A reconnect's own clock restarts at zero — `reset()` must not let the new connection's
    /// early timestamps resolve against the previous connection's chunks.
    func testResetClearsPriorConnectionEntriesEntirely() {
        var timeline = SessionTimeline()
        timeline.recordTransmittedChunk(sessionSampleStart: 0, takeOffset: 0, sampleCount: 16000)
        timeline.reset()
        timeline.recordTransmittedChunk(sessionSampleStart: 0, takeOffset: 200_000, sampleCount: 16000)

        let range = timeline.takeRange(startSeconds: 0.0, endSeconds: 0.5, sampleRate: sampleRate)
        XCTAssertEqual(range, 200_000..<208_000)
    }

    func testNilForATimestampWithNoTransmittedChunkToExplainIt() {
        let timeline = SessionTimeline()
        XCTAssertNil(timeline.takeRange(startSeconds: 0.0, endSeconds: 0.1, sampleRate: sampleRate))
    }

    func testNextSessionSampleStartTracksTheRunningTotal() {
        var timeline = SessionTimeline()
        XCTAssertEqual(timeline.nextSessionSampleStart, 0)
        timeline.recordTransmittedChunk(sessionSampleStart: 0, takeOffset: 0, sampleCount: 1600)
        XCTAssertEqual(timeline.nextSessionSampleStart, 1600)
        timeline.recordTransmittedChunk(sessionSampleStart: 1600, takeOffset: 1600, sampleCount: 2400)
        XCTAssertEqual(timeline.nextSessionSampleStart, 4000)
    }
}
