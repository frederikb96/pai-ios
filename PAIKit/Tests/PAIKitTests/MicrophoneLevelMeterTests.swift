import XCTest

@testable import PAIKit

final class MicrophoneLevelMeterTests: XCTestCase {
    /// 100 ms of 16 kHz samples whose RMS sits at `db` dBFS.
    private static func chunk(db: Double) -> [Int16] {
        let amplitude = Int16((32768 * pow(10, db / 20)).rounded())
        return (0..<1600).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
    }

    /// A meter that has spent `seconds` in a room at `roomDb`.
    private static func meter(inRoomAt roomDb: Double, seconds: Int = 3) -> MicrophoneLevelMeter {
        var meter = MicrophoneLevelMeter()
        for _ in 0..<(seconds * 10) { meter.push(samples: chunk(db: roomDb)) }
        return meter
    }

    func testSpeechFromAcrossTheDeskInAQuietRoomIsHeardAndVisible() {
        var meter = Self.meter(inRoomAt: -95)
        let reading = meter.push(samples: Self.chunk(db: -65))
        XCTAssertTrue(reading.heard)
        XCTAssertGreaterThan(reading.level, 0.15)
    }

    func testAWhisperInAQuietRoomIsHeardAndVisible() {
        var meter = Self.meter(inRoomAt: -85)
        let reading = meter.push(samples: Self.chunk(db: -60))
        XCTAssertTrue(reading.heard)
        XCTAssertGreaterThan(reading.level, 0.15)
    }

    func testALoudRoomStaysAtTheBottomWhileSpeechAboveItStillRises() {
        var meter = Self.meter(inRoomAt: -45)
        let room = meter.push(samples: Self.chunk(db: -45))
        XCTAssertFalse(room.heard)
        XCTAssertLessThan(room.level, 0.05)
        var other = Self.meter(inRoomAt: -45)
        XCTAssertGreaterThan(other.push(samples: Self.chunk(db: -25)).level, 0.4)
    }

    func testTheBarFadesAfterTheVoiceStopsInsteadOfDroppingToTheBottom() {
        var meter = Self.meter(inRoomAt: -90)
        let word = meter.push(samples: Self.chunk(db: -40)).level
        let first = meter.push(samples: Self.chunk(db: -90)).level
        let second = meter.push(samples: Self.chunk(db: -90)).level
        XCTAssertLessThan(first, word)
        XCTAssertLessThan(second, first)
        XCTAssertGreaterThan(second, 0)
    }

    func testMutedChunksTeachTheRoomNothing() {
        var meter = Self.meter(inRoomAt: -50)
        for _ in 0..<100 { meter.pushMuted() }
        // Still the loud room it was before the mute: its own noise is not speech.
        XCTAssertFalse(meter.push(samples: Self.chunk(db: -50)).heard)
    }

    func testLevelNeverLeavesZeroToOneAndNeverReadsALouderChunkAsQuieter() {
        let levels = [-100.0, -80, -70, -60, -50, -40, -30, -18, 0].map {
            MicrophoneLevelMeter.level(db: $0, floorDb: -90)
        }
        XCTAssertTrue(levels.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertEqual(levels, levels.sorted())
    }

    func testAStalledMicrophoneIsNotHearingWhateverTheLastReadingSaid() {
        let loud = MicrophoneLevelMeter.Reading(level: 0.9, heard: true)
        XCTAssertEqual(MicrophoneHealthState(stalled: true, reading: loud), .notHearing)
        XCTAssertEqual(MicrophoneHealthState(stalled: false, reading: loud), .hearing(level: 0.9))
        XCTAssertEqual(
            MicrophoneHealthState(stalled: false, reading: .init(level: 0.3, heard: false)), .quiet)
    }
}
