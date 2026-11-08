import Foundation

/// What the level display shows for each captured chunk, and whether the chunk counts as hearing
/// someone.
///
/// Loudness is logarithmic, so the bar follows decibels. Its scale is measured from the room
/// rather than fixed: the same voice reaches the microphone 20–30 dB quieter from a phone lying
/// on a desk than from one held to the mouth, and a whisper quieter still. The bar starts where
/// the silence gate would hear speech in this room (`SilenceGate.speechThresholdDb`), so the
/// display and the gate never disagree about whether the person is being heard.
///
/// Fed the same chunks the gate sees (gain applied, 16 kHz); a chunk captured while muted fades
/// the bar and teaches the room nothing.
public struct MicrophoneLevelMeter: Sendable {
    public struct Reading: Equatable, Sendable {
        /// `0...1`, eased, falling gradually once the voice gets quieter.
        public var level: Double
        /// The latest chunk rose to speech in this room.
        public var heard: Bool

        public init(level: Double, heard: Bool) {
            self.level = level
            self.heard = heard
        }
    }

    /// The bar is full this far above where it starts, or at `ceilingDb` if that comes first.
    public static let spanDb = 40.0
    /// The bar is always full at this level: loud, clear speech close to the microphone.
    public static let ceilingDb = -18.0
    /// However loud the room, the bar keeps at least this range.
    public static let minSpanDb = 20.0
    /// Above 1 pushes the low end down, so a sound just above the room reads as low rather than
    /// as a third of the bar.
    static let easing = 1.6
    /// Share of the previous level kept per chunk once the voice gets quieter.
    static let release = 0.6

    public private(set) var reading = Reading(level: 0, heard: false)
    private var room = RoomFloor()

    public init() {}

    /// 0...1 for a chunk at `db` in a room whose floor is `floorDb`.
    public static func level(db: Double, floorDb: Double) -> Double {
        let low = SilenceGate.speechThresholdDb(floorDb: floorDb)
        let high = max(low + minSpanDb, min(low + spanDb, ceilingDb))
        let linear = min(1, max(0, (db - low) / (high - low)))
        return pow(linear, easing)
    }

    /// One captured chunk of 16 kHz samples.
    @discardableResult
    public mutating func push(samples: [Int16]) -> Reading {
        let db = SilenceGate.levelDb(samples)
        room.observe(levelDb: db, durationMs: Double(samples.count) * 1000 / Double(VoiceSocketProtocol.audioUplinkHz))
        let floorDb = room.floorDb
        reading = Reading(
            level: max(Self.level(db: db, floorDb: floorDb), reading.level * Self.release),
            heard: db >= SilenceGate.speechThresholdDb(floorDb: floorDb))
        return reading
    }

    /// A chunk that was not listened to: the bar fades and the room is left as it was.
    @discardableResult
    public mutating func pushMuted() -> Reading {
        reading = Reading(level: reading.level * Self.release, heard: false)
        return reading
    }

    public mutating func reset() {
        room.reset()
        reading = Reading(level: 0, heard: false)
    }
}
