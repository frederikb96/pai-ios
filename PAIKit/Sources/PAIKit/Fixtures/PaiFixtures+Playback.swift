import Foundation

extension PaiFixtures {
    /// The assistant reply of the corpus the playback screens read: it has prose and a first-words
    /// title, and `GET /api/session/{id}/playback/{message_id}` answers for it.
    public static let playbackReplyId = 9054

    /// `GET /api/session/{id}/playback/{message_id}` — two short segments, nothing synthesised yet.
    public static let playbackManifest: String = #"""
        {
          "message_id": 9054, "voice_id": null, "model": "eleven_flash_v2_5",
          "segments": [
            { "index": 0, "chars": 180, "est_ms": 2000, "duration_ms": null, "ready": false,
              "provider": null, "fallback": false },
            { "index": 1, "chars": 160, "est_ms": 2000, "duration_ms": null, "ready": false,
              "provider": null, "fallback": false }
          ],
          "usage": {
            "credits_used": 1200, "daily_credit_cap": 5000, "resets_at": "2026-08-30T00:00:00+00:00",
            "backup": { "available": true, "budget_cents": 200, "spent_cents": 0 }
          }
        }
        """#

    /// `GET /api/playback/voices` — a short account list; the person has picked none, so the
    /// default (George) reads for them.
    public static let playbackVoices: String = #"""
        {
          "elevenlabs": [
            { "voice_id": "JBFqnCBsd6RMkjVDRZzb", "name": "George", "language": "en", "gender": "male" },
            { "voice_id": "nztoarMvjgs3c0c5DINJ", "name": "Oma Elisabeth", "language": "de", "gender": "female" },
            { "voice_id": "EXAVITQu4vr4xnSDxMaL", "name": "Sarah", "language": null, "gender": "female" }
          ],
          "default_voice_id": "JBFqnCBsd6RMkjVDRZzb", "builtin_voice_id": "JBFqnCBsd6RMkjVDRZzb",
          "backup": ["marin", "cedar", "alloy"], "backup_voice": "marin"
        }
        """#

    /// The refusal `-PaiFixturePlayback error` answers the manifest with: `detail` is an object.
    public static let playbackRefused: String = #"""
        { "detail": { "code": "playback_cap_reached", "message": "Today's playback limit is reached. It resets at midnight." } }
        """#

    /// A silent mono 8 kHz, 8-bit WAV: audio any player accepts, without a recording in the repo.
    public static func silentWav(seconds: Int) -> Data {
        let rate = 8000
        let samples = rate * seconds
        func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> ($0 * 8)) & 0xff) } }
        func le16(_ value: Int) -> [UInt8] { (0..<2).map { UInt8((value >> ($0 * 8)) & 0xff) } }
        var bytes: [UInt8] = Array("RIFF".utf8) + le32(36 + samples) + Array("WAVEfmt ".utf8)
        bytes += le32(16) + le16(1) + le16(1) + le32(rate) + le32(rate) + le16(1) + le16(8)
        bytes += Array("data".utf8) + le32(samples) + [UInt8](repeating: 128, count: samples)
        return Data(bytes)
    }
}
