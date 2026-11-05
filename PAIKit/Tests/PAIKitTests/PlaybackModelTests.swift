import XCTest

@testable import PAIKit

func playbackReply(id: Int, session: String = "s1", type: MessageType = .assistant, content: String?) -> Message {
    Message(
        id: id, sessionId: session, type: type, subtype: nil, outboxId: nil, timestamp: "2026-11-04T10:00:00Z",
        content: content, thinking: nil, toolCalls: nil, toolResult: nil, hookSummary: nil, tokens: nil,
        origin: nil, originMeta: nil, notificationMarker: nil, createdAt: nil)
}

func playbackManifest(messageId: Int = 1, estMs: [Int], durationsMs: [Int?]? = nil) -> PlaybackManifest {
    PlaybackManifest(
        messageId: messageId, voiceId: nil, model: "m",
        segments: estMs.enumerated().map { index, est in
            PlaybackSegment(
                index: index, chars: 100, estMs: est, durationMs: durationsMs?[index],
                ready: durationsMs?[index] != nil)
        },
        usage: PlaybackUsage(creditsUsed: 0, dailyCreditCap: 1000, resetsAt: "2026-11-05T00:00:00Z", backup: nil))
}

extension PlaybackManifest {
    init(messageId: Int, voiceId: String?, model: String, segments: [PlaybackSegment], usage: PlaybackUsage) {
        self = try! JSONDecoder().decode(
            PlaybackManifest.self,
            from: JSONSerialization.data(withJSONObject: [
                "message_id": messageId, "voice_id": voiceId as Any, "model": model,
                "segments": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(segments)),
                "usage": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(usage)),
            ]))
    }
}

extension PlaybackUsage {
    init(creditsUsed: Int, dailyCreditCap: Int?, resetsAt: String, backup: PlaybackBackupUsage?) {
        let object: [String: Any] = [
            "credits_used": creditsUsed, "daily_credit_cap": dailyCreditCap as Any, "resets_at": resetsAt,
        ]
        self = try! JSONDecoder().decode(
            PlaybackUsage.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

final class PlaybackModelTests: XCTestCase {
    func testPositionMathAcrossSegments() {
        let durations = [10_000, 20_000, 5_000]
        XCTAssertEqual(PlaybackModel.locate(durationsMs: durations, positionMs: 0).index, 0)
        XCTAssertEqual(PlaybackModel.locate(durationsMs: durations, positionMs: 9_999).index, 0)
        let second = PlaybackModel.locate(durationsMs: durations, positionMs: 10_000)
        XCTAssertEqual(second.index, 1)
        XCTAssertEqual(second.offsetMs, 0)
        let third = PlaybackModel.locate(durationsMs: durations, positionMs: 31_000)
        XCTAssertEqual(third.index, 2)
        XCTAssertEqual(third.offsetMs, 1_000)
        let past = PlaybackModel.locate(durationsMs: durations, positionMs: 99_000)
        XCTAssertEqual(past.index, 2)
        XCTAssertEqual(past.offsetMs, 5_000, "clamped to the end")
        XCTAssertEqual(PlaybackModel.positionOf(durationsMs: durations, index: 2, offsetMs: 1_000), 31_000)
    }

    func testMeasuredLengthsWinOverTheServersEstimates() {
        let manifest = playbackManifest(estMs: [10_000, 10_000, 10_000], durationsMs: [9_000, nil, nil])
        XCTAssertEqual(PlaybackModel.segmentDurationsMs(manifest, measured: [:]), [9_000, 10_000, 10_000])
        XCTAssertEqual(
            PlaybackModel.segmentDurationsMs(manifest, measured: [0: 9_500, 1: 11_000]), [9_500, 11_000, 10_000])
    }

    func testTheClockReadsMinutesAndSeconds() {
        XCTAssertEqual(PlaybackModel.formatClock(0), "0:00")
        XCTAssertEqual(PlaybackModel.formatClock(61_400), "1:01")
        XCTAssertEqual(PlaybackModel.formatClock(-5), "0:00")
    }

    func testAFileMarkerLineIsNotSpeech() {
        let content = "Here is the file.\npai-file: /tmp/report.pdf"
        XCTAssertEqual(PlaybackModel.replyText(content), "Here is the file.")
        XCTAssertFalse(PlaybackModel.isPlayable(playbackReply(id: 1, content: "pai-file: /tmp/a.png")))
        XCTAssertFalse(PlaybackModel.isPlayable(playbackReply(id: 1, content: "  \n ")))
        XCTAssertFalse(PlaybackModel.isPlayable(playbackReply(id: 1, content: nil)))
        XCTAssertFalse(PlaybackModel.isPlayable(playbackReply(id: 1, type: .user, content: "hello")))
        XCTAssertTrue(PlaybackModel.isPlayable(playbackReply(id: 1, content: "hello")))
    }

    func testTheSnippetIsPlainAndShort() {
        let message = playbackReply(
            id: 1, content: "## Heading\n\nSome **bold** text with a [link](https://x.y) and `code`.\n```\nskip\n```")
        XCTAssertEqual(PlaybackModel.snippet(of: message), "Heading Some bold text with a link and code.")
        XCTAssertEqual(PlaybackModel.snippet(of: playbackReply(id: 2, content: "```\nonly code\n```")), "Reply")
        let long = playbackReply(id: 3, content: String(repeating: "word ", count: 40))
        XCTAssertTrue(PlaybackModel.snippet(of: long).hasSuffix("…"))
        XCTAssertLessThanOrEqual(PlaybackModel.snippet(of: long).count, 61)
    }

    func testARefusalCarriesTheServersOwnSentence() {
        let body = #"{"detail":{"code":"playback_cap_reached","message":"Today's playback limit is reached."}}"#
        let refusal = PlaybackRefusal.parse(status: 429, body: Data(body.utf8))
        XCTAssertEqual(refusal.code, "playback_cap_reached")
        XCTAssertEqual(refusal.message, "Today's playback limit is reached.")
        let plain = PlaybackRefusal.parse(status: 404, body: Data(#"{"detail":"No speech"}"#.utf8))
        XCTAssertEqual(plain.message, "No speech")
        XCTAssertTrue(plain.isNothingToRead)
        XCTAssertEqual(PlaybackRefusal.parse(status: 502, body: Data()).message, "HTTP 502")
    }

    func testTheManifestDecodesTheContractShapeAndAnUnknownVoiceReadsAsNone() throws {
        let json = """
            {"message_id": 9, "voice_id": null, "model": "eleven_flash_v2_5",
             "segments": [
               {"index": 0, "chars": 120, "est_ms": 8000, "duration_ms": 7900, "ready": true, "provider": "openai", "fallback": true},
               {"index": 1, "chars": 90, "est_ms": 6000, "duration_ms": null, "ready": false, "provider": "someone-new", "fallback": false}],
             "usage": {"credits_used": 12, "daily_credit_cap": 5000, "allowance_limited": true, "allowance_credits": 800,
                       "available_credits": 640, "resets_at": "2026-11-05T00:00:00+00:00",
                       "backup": {"available": true, "budget_cents": 200, "spent_cents": 10}}}
            """
        let manifest = try JSONDecoder().decode(PlaybackManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.segments.map(\.provider), [.openai, nil])
        XCTAssertTrue(manifest.segments[0].fallback)
        XCTAssertEqual(manifest.usage.dailyCreditCap, 5000, "the allowance keys an older server sends are ignored")
        XCTAssertEqual(manifest.usage.backup?.budgetCents, 200)
    }

    func testUsageDecodesWithoutTheRemovedKeysAndWithANullCeiling() throws {
        let json = #"{"credits_used": 0, "daily_credit_cap": null, "resets_at": "2026-11-05T00:00:00+00:00"}"#
        let usage = try JSONDecoder().decode(PlaybackUsage.self, from: Data(json.utf8))
        XCTAssertNil(usage.dailyCreditCap)
        XCTAssertNil(usage.backup)
    }

    func testOnlyThePartFailuresAreRefusalsAboutOnePart() {
        func refusal(_ code: String?) -> PlaybackRefusal { PlaybackRefusal(status: 502, code: code, message: "m") }
        XCTAssertTrue(refusal("playback_backup_failed").isPartFailure)
        XCTAssertTrue(refusal("playback_synthesis_failed").isPartFailure)
        for other in ["playback_saving_credits", "playback_cap_reached", nil] {
            XCTAssertFalse(refusal(other).isPartFailure, "\(other ?? "no code") is a limit, not one part")
        }
    }

    func testTheVoiceListDecodesAndNamesItsVoicesAndTheDefault() throws {
        let voices = try JSONDecoder().decode(PlaybackVoices.self, from: Data(PaiFixtures.playbackVoices.utf8))
        XCTAssertEqual(voices.elevenlabs.map(\.label), ["George (en)", "Oma Elisabeth (de)", "Sarah"])
        XCTAssertEqual(voices.defaultVoiceLabel, "George (en)")
        XCTAssertEqual(voices.backup, ["marin", "cedar", "alloy"])
    }

    func testAVoiceValueStandsOnTheDefaultAListedVoiceOrACustomId() throws {
        let listed = try JSONDecoder().decode(PlaybackVoices.self, from: Data(PaiFixtures.playbackVoices.utf8))
            .elevenlabs
        XCTAssertEqual(PlaybackVoiceSelection.of(nil, listed: listed), .defaultVoice)
        XCTAssertEqual(PlaybackVoiceSelection.of("", listed: listed), .defaultVoice)
        XCTAssertEqual(
            PlaybackVoiceSelection.of("nztoarMvjgs3c0c5DINJ", listed: listed), .listed("nztoarMvjgs3c0c5DINJ"))
        XCTAssertEqual(PlaybackVoiceSelection.of("someone-else", listed: listed), .custom)
        XCTAssertEqual(
            PlaybackVoiceSelection.of("someone-else", listed: []), .custom, "an unreadable account lists nothing")
    }
}
