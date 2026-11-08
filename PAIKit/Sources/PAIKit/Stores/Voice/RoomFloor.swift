import Foundation

/// The room's level: a duration-weighted percentile of the recent frame levels. Speech always
/// leaves gaps between words, so the low percentile is the room even while someone talks without
/// pause. Shared by the silence gate and the level meter, which is what keeps the gate's idea of
/// "speech" and the display's the same.
struct RoomFloor: Sendable {
    private var history: [(levelDb: Double, durationMs: Double)] = []

    /// Milliseconds of audio currently in the window.
    var historyMs: Double { history.reduce(0) { $0 + $1.durationMs } }

    /// Whether enough audio has been seen to trust `floorDb`.
    var isMeasured: Bool { historyMs >= SilenceGate.floorMinHistoryMs }

    mutating func observe(levelDb: Double, durationMs: Double) {
        history.append((levelDb, durationMs))
        var total = historyMs
        while let first = history.first, total - first.durationMs >= SilenceGate.floorWindowMs {
            history.removeFirst()
            total -= first.durationMs
        }
    }

    var floorDb: Double {
        let total = historyMs
        guard total > 0 else { return SilenceGate.silentDb }
        let sorted = history.sorted { $0.levelDb < $1.levelDb }
        var cumulative = 0.0
        for entry in sorted {
            cumulative += entry.durationMs
            if cumulative >= total * SilenceGate.floorPercentile { return entry.levelDb }
        }
        return sorted.last?.levelDb ?? SilenceGate.silentDb
    }

    mutating func reset() {
        history = []
    }
}
