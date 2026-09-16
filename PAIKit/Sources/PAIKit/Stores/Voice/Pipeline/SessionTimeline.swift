import Foundation

/// Maps one realtime connection's own elapsed audio — seconds since *that connection's* first
/// transmitted sample — to sample offsets in the take. Necessary because the two clocks disagree:
/// a withheld silence-gate stretch never reaches the socket at all, keepalive silence and gate
/// pre-roll do reach it, and every reconnect starts the connection's own clock back at zero. A
/// word's `(start, end)` from `RealtimeWordTimestamp` only means something once it is looked up
/// here.
///
/// `reset()` on every new connection — a fresh instance would do exactly as well, but the session
/// reuses one across reconnects rather than juggling construction at each retry.
public struct SessionTimeline: Sendable, Equatable {
    private struct Entry: Sendable, Equatable {
        let sessionSampleStart: Int
        let takeOffsetStart: Int
        let sampleCount: Int
    }

    private var entries: [Entry] = []

    public init() {}

    /// Call once per chunk actually transmitted to the socket, in send order — a chunk buffered
    /// and never sent (a take that stopped before flushing) must never be recorded here.
    public mutating func recordTransmittedChunk(sessionSampleStart: Int, takeOffset: Int, sampleCount: Int) {
        guard sampleCount > 0 else { return }
        entries.append(Entry(sessionSampleStart: sessionSampleStart, takeOffsetStart: takeOffset, sampleCount: sampleCount))
    }

    /// The connection's own sample count as of its next transmitted chunk — what a caller passes
    /// as `sessionSampleStart` to keep the running count without maintaining it separately.
    public var nextSessionSampleStart: Int { (entries.last.map { $0.sessionSampleStart + $0.sampleCount }) ?? 0 }

    /// A fresh connection starts its own sample clock at zero again.
    public mutating func reset() {
        entries.removeAll()
    }

    /// Converts a word's connection-relative `(start, end)` seconds into a take sample range.
    /// `nil` when nothing transmitted on this connection could explain the interval — an entirely
    /// out-of-range timestamp, which a caller treats as "cannot place this word" rather than
    /// guessing.
    public func takeRange(startSeconds: Double, endSeconds: Double, sampleRate: Int) -> SampleRange? {
        guard let start = takeOffset(forSessionSample: Int((startSeconds * Double(sampleRate)).rounded())),
            let end = takeOffset(forSessionSample: Int((endSeconds * Double(sampleRate)).rounded()))
        else { return nil }
        guard start < end else { return nil }
        return start..<end
    }

    /// Each entry's session range is half-open — `[start, start + count)` — matching every other
    /// range in this pipeline. This matters at an exact chunk boundary where two consecutive
    /// entries carry a *take*-side discontinuity (a withheld gate stretch between them): the
    /// boundary sample is the next entry's first sample, never the previous entry's one-past-end,
    /// so a word starting exactly there is placed after the gap rather than before it.
    private func takeOffset(forSessionSample sessionSample: Int) -> Int? {
        for entry in entries {
            let entryEnd = entry.sessionSampleStart + entry.sampleCount
            if sessionSample >= entry.sessionSampleStart, sessionSample < entryEnd {
                return entry.takeOffsetStart + (sessionSample - entry.sessionSampleStart)
            }
        }
        // At or past the last known chunk's end — ElevenLabs' own word boundary can land a
        // handful of samples beyond what has been recorded as transmitted so far; extrapolate
        // from the last entry rather than failing a word that is otherwise perfectly placeable.
        if let last = entries.last {
            let lastEnd = last.sessionSampleStart + last.sampleCount
            if sessionSample >= lastEnd {
                return last.takeOffsetStart + last.sampleCount + (sessionSample - lastEnd)
            }
        }
        return nil
    }
}
