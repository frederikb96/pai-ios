import Foundation

/// Whether the gate adapts its threshold to the room or uses a fixed one.
public enum SilenceGateMode: String, Codable, Sendable, CaseIterable {
    case auto, manual
}

/// The client-local silence gate setting — never synced, since the threshold is a property of
/// this device's microphones and rooms.
public struct SilenceGateSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var mode: SilenceGateMode
    /// dBFS, used only in `.manual`.
    public var manualThresholdDb: Int

    public static let standard = SilenceGateSettings(
        enabled: true, mode: .auto, manualThresholdDb: SilenceGate.manualDefaultDb)
    public static let manualRange = -70...(-20)

    public init(enabled: Bool, mode: SilenceGateMode, manualThresholdDb: Int) {
        self.enabled = enabled
        self.mode = mode
        self.manualThresholdDb = manualThresholdDb
    }
}

/// The client half of withheld silence (`docs/VOICE_PROTOCOL.md` "Withheld silence"): measures the
/// level of every frame about to go up the voice socket and, after a sustained quiet stretch,
/// stops sending until speech returns — keeping the last second in a ring so the first word after
/// the quiet is never cut. The backend holds its sessions open meanwhile; it only needs the
/// `silence` frame this produces.
///
/// One algorithm in three clients (web `silenceGate.ts`, pai-stt `silence_gate.py`, this), held
/// together by the same test vectors in each suite rather than by shared code. Every timer runs
/// in milliseconds of audio, never in frame counts, because each client delivers frames of a
/// different size.
///
/// A pure value: the caller feeds frames and sends what comes back, in order.
public struct SilenceGate: Sendable {
    public static let quietWindowMs = 5000.0
    public static let prerollMs = 1000.0
    public static let floorWindowMs = 8000.0
    public static let floorPercentile = 0.10
    public static let floorMinHistoryMs = 1000.0
    public static let autoMarginDb = 8.0
    public static let autoOpenMinDb = -60.0
    /// A floor above this means a loud room, where withholding would risk cutting speech — the
    /// gate then never withholds. Withheld speech is the one failure that must never happen;
    /// paying for some silence is the acceptable one.
    public static let autoMaxFloorDb = -50.0
    public static let hysteresisDb = 3.0
    public static let onsetMs = 150.0
    public static let loudOnsetDb = 10.0
    public static let manualDefaultDb = -45
    public static let silentDb = -100.0

    /// One frame exactly as it would go up the socket, with its level measured once.
    public struct Frame: Sendable, Equatable {
        public let offset: Int
        public let samples: [Int16]
        public let levelDb: Double

        public var endOffset: Int { offset + samples.count }
        var durationMs: Double { Double(samples.count) * 1000 / Double(VoiceSocketProtocol.audioUplinkHz) }

        public init(offset: Int, samples: [Int16]) {
            self.offset = offset
            self.samples = samples
            self.levelDb = SilenceGate.levelDb(samples)
        }
    }

    /// What to send for one input, in order: `send` first, then — when set — the `silence`
    /// frame naming where withholding starts.
    public struct Output: Sendable, Equatable {
        public var send: [Frame] = []
        public var silenceAt: Int?
    }

    public let settings: SilenceGateSettings
    /// What the backend last said (`silence_allowed` on `ready`/`state`). Withholding is never
    /// started while this is false, and stops the moment it turns false.
    public private(set) var allowed = false
    public private(set) var isWithholding = false
    /// The end offset of the last frame sent before withholding began — the `silence` frame's
    /// `at_sample`.
    public private(set) var withheldFrom: Int?

    private var floorHistory: [(levelDb: Double, durationMs: Double)] = []
    private var quietMs = 0.0
    private var aboveRunMs = 0.0
    private var ring: [Frame] = []

    public init(settings: SilenceGateSettings) {
        self.settings = settings
    }

    /// RMS of the samples in dBFS, clamped at `silentDb` for digital zero.
    public static func levelDb(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return silentDb }
        var sum = 0.0
        for sample in samples {
            let value = Double(sample) / 32768
            sum += value * value
        }
        let rms = (sum / Double(samples.count)).squareRoot()
        return 20 * log10(max(rms, 1e-5))
    }

    /// Back to streaming with no memory of the room: at take start, on every `ready`, and on an
    /// input route change — a different microphone has a different floor. Whatever the ring held
    /// is dropped; it was already accounted for locally and never needs sending.
    public mutating func reset() {
        isWithholding = false
        withheldFrom = nil
        floorHistory = []
        quietMs = 0
        aboveRunMs = 0
        ring = []
    }

    /// The backend's `silence_allowed`. Turning false while withholding resumes at once, sending
    /// the ring.
    public mutating func setAllowed(_ allowed: Bool) -> Output {
        self.allowed = allowed
        guard !allowed, isWithholding else { return Output() }
        return Output(send: resume())
    }

    public mutating func push(offset: Int, samples: [Int16]) -> Output {
        let frame = Frame(offset: offset, samples: samples)
        recordFloor(frame)
        let thresholds = currentThresholds()

        if isWithholding {
            ring.append(frame)
            trimRing()
            aboveRunMs = frame.levelDb >= thresholds.open ? aboveRunMs + frame.durationMs : 0
            let shouldResume =
                aboveRunMs >= Self.onsetMs || frame.levelDb >= thresholds.open + Self.loudOnsetDb || !allowed
                || !settings.enabled || (settings.mode == .auto && !floorPermitsWithholding)
            return shouldResume ? Output(send: resume()) : Output()
        }

        quietMs = isQuiet(frame, close: thresholds.close) ? quietMs + frame.durationMs : 0
        guard settings.enabled, allowed, quietMs >= Self.quietWindowMs else { return Output(send: [frame]) }
        if settings.mode == .auto {
            guard historyMs >= Self.floorMinHistoryMs, floorPermitsWithholding else { return Output(send: [frame]) }
        }
        isWithholding = true
        withheldFrom = frame.endOffset
        aboveRunMs = 0
        ring = []
        return Output(send: [frame], silenceAt: frame.endOffset)
    }

    /// The stop rule while withholding: the ring is sent only when it holds something above the
    /// open threshold — speech that began right as stop was pressed — and otherwise nothing is.
    public mutating func stopFlush() -> [Frame] {
        guard isWithholding else { return [] }
        let open = currentThresholds().open
        let flushed = ring.contains { $0.levelDb >= open } ? ring : []
        reset()
        return flushed
    }

    /// The ack watermark to keep while withheld audio counts as accounted for: once everything up
    /// to where withholding began has been acknowledged, every frame captured since is settled
    /// too — recorded locally, deliberately never sent, never to be backfilled.
    public func accountedWatermark(acked: Int, capturedUpTo: Int) -> Int {
        guard isWithholding, let withheldFrom, acked >= withheldFrom else { return acked }
        return max(acked, capturedUpTo)
    }

    // MARK: - Internals

    private mutating func resume() -> [Frame] {
        let flushed = ring
        isWithholding = false
        withheldFrom = nil
        ring = []
        quietMs = 0
        aboveRunMs = 0
        return flushed
    }

    private mutating func recordFloor(_ frame: Frame) {
        guard settings.mode == .auto else { return }
        floorHistory.append((frame.levelDb, frame.durationMs))
        var total = historyMs
        while let first = floorHistory.first, total - first.durationMs >= Self.floorWindowMs {
            floorHistory.removeFirst()
            total -= first.durationMs
        }
    }

    private var historyMs: Double { floorHistory.reduce(0) { $0 + $1.durationMs } }

    /// Duration-weighted percentile of the levels in the window.
    private var floorDb: Double {
        let total = historyMs
        guard total > 0 else { return Self.silentDb }
        let sorted = floorHistory.sorted { $0.levelDb < $1.levelDb }
        var cumulative = 0.0
        for entry in sorted {
            cumulative += entry.durationMs
            if cumulative >= total * Self.floorPercentile { return entry.levelDb }
        }
        return sorted.last?.levelDb ?? Self.silentDb
    }

    private var floorPermitsWithholding: Bool { floorDb <= Self.autoMaxFloorDb }

    /// Below the close threshold — and, in auto mode, also below the loud-room ceiling. The floor
    /// is estimated from the stream itself, so at the start of a take (speech with no room tone
    /// heard yet) the floor IS the speech level and the close threshold sits above it; without
    /// the ceiling, the opening sentence would count towards the quiet window. A frame that loud
    /// is never room tone the gate could withhold anyway.
    private func isQuiet(_ frame: Frame, close: Double) -> Bool {
        guard frame.levelDb < close else { return false }
        return settings.mode == .manual || frame.levelDb < Self.autoMaxFloorDb
    }

    private func currentThresholds() -> (open: Double, close: Double) {
        let open: Double =
            switch settings.mode {
            case .manual: Double(settings.manualThresholdDb)
            case .auto: max(floorDb + Self.autoMarginDb, Self.autoOpenMinDb)
            }
        return (open, open - Self.hysteresisDb)
    }

    /// Keeps the shortest suffix of whole frames totalling at least the pre-roll.
    private mutating func trimRing() {
        var total = ring.reduce(0) { $0 + $1.durationMs }
        while let first = ring.first, total - first.durationMs >= Self.prerollMs {
            ring.removeFirst()
            total -= first.durationMs
        }
    }
}
