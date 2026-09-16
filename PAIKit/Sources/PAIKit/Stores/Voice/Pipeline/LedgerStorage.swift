import Foundation

/// Where a take's ledger lives — a sandboxed path (`FileManager.default.urls(for:in:)`) that
/// `LedgerFile`'s pure Foundation code cannot know for itself, the same split
/// `RecordingAudioStorage` (`RecordingsStore.swift`) already draws for a take's audio.
public protocol LedgerStorage: Sendable {
    func ledgerURL(id: String) -> URL
}

/// Reads back a range of a take's own sent audio — the batch backfill's only need from disk. The
/// range is already in bytes past the header (`WavByteRange`, `TakeAddressing.swift`); an
/// implementation is a seek and a read over the sandboxed file `LedgerStorage` names for the same
/// take id.
public protocol TakeAudioReader: Sendable {
    func readSamples(id: String, range: WavByteRange) async throws -> Data
}

/// Stand-ins for `VoiceRecordingDependencies`' new fields until `VoiceRecorderController` wires
/// the real, sandboxed implementations. Nothing in this package calls either yet — they exist
/// only so today's construction sites keep compiling with today's behaviour. `public` because a
/// default argument value must be at least as accessible as the initializer it defaults for.
public struct UnconfiguredLedgerStorage: LedgerStorage {
    public init() {}
    public func ledgerURL(id: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(id)-ledger.json")
    }
}

public struct UnconfiguredTakeAudioReader: TakeAudioReader {
    public init() {}
    public func readSamples(id: String, range: WavByteRange) async throws -> Data {
        throw VoiceTransportError.notConnected
    }
}
