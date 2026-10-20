import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// What this device remembers about a take the server owns, persisted in the take's ledger so it
/// survives the app being killed. A take is *owed* from the moment it stops until its result is
/// applied here: the server has (or will be given) every sample, and this device keeps uploading
/// what is missing and asking for the result until the take is `done`.
public struct PendingServerTake: Codable, Sendable, Equatable {
    public var mode: VoiceSttMode
    /// A recording with no draft; its result lands on the recording only.
    public var standalone: Bool
    public var standaloneName: String?
    /// The take's length, fixed when it stopped; `nil` while it is still recording.
    public var capturedSamples: Int?
    public var withheld: [SampleRange]
    /// The take's own words as this device last wrote them into the draft, `stt-rec: ` included —
    /// what the server's final text replaces.
    public var insertedText: String?
    /// The send that carries this take. Its words went to the session with it, so the result is
    /// never healed into the draft.
    public var heldClientMessageId: String?
    /// The server's last answer, for what the recordings list shows.
    public var lastState: VoiceTakeState?
    /// Nothing is owed any more: the result was applied, or the take finished cleanly on the
    /// socket.
    public var settled: Bool
    /// Why the last attempt stopped for good — a refusal no retry changes, or audio this device
    /// does not have. Still owed, and tried again on the next resume, but nothing a later send
    /// should wait on.
    public var stuckReason: String?

    public init(
        mode: VoiceSttMode, standalone: Bool = false, standaloneName: String? = nil, capturedSamples: Int? = nil,
        withheld: [SampleRange] = [], insertedText: String? = nil, heldClientMessageId: String? = nil,
        lastState: VoiceTakeState? = nil, settled: Bool = false, stuckReason: String? = nil
    ) {
        self.mode = mode
        self.standalone = standalone
        self.standaloneName = standaloneName
        self.capturedSamples = capturedSamples
        self.withheld = withheld
        self.insertedText = insertedText
        self.heldClientMessageId = heldClientMessageId
        self.lastState = lastState
        self.settled = settled
        self.stuckReason = stuckReason
    }

    /// Stopped and still waiting on the server.
    public var isOwed: Bool { capturedSamples != nil && !settled }

    /// The REST seal for this take — the same length and withheld stretches the closing gate
    /// carried, so a repeat is a no-op on the server.
    public func seal(draftKey: String?, device: String?) -> VoiceTakeSeal? {
        guard let capturedSamples else { return nil }
        return VoiceTakeSeal(
            mode: mode, capturedSamples: capturedSamples, withheld: withheld.isEmpty ? nil : withheld,
            draftKey: standalone ? nil : draftKey, standaloneName: standalone ? standaloneName : nil, device: device)
    }
}

/// The calls an owed take needs, narrowed so a test can fake the server.
public protocol VoiceTakeAPI: Sendable {
    func getVoiceTake(takeId: String) async throws -> VoiceTake
    func sealVoiceTake(takeId: String, seal: VoiceTakeSeal) async throws -> VoiceTake
    func uploadVoiceTakeAudio(takeId: String, range: SampleRange, wav: Data, device: String?) async throws -> VoiceTake
}

extension PaiApiClient: VoiceTakeAPI {}

/// Sees one owed take through to its result: seal, upload whatever the server lists as
/// missing from the take's own recording, then ask until the take is `done` or `failed`. No
/// decision here depends on what this device believes it sent — the server's `missing` is the
/// one authority — so a take resumed after a kill, a reinstall of the ledger or a pod restart is
/// driven exactly like one that just stopped.
public enum OwedTakeDriver {
    /// One upload never carries more than this: a lost request on a poor link costs a minute of
    /// audio to resend, not the whole outage.
    public static let uploadPieceSeconds = 60
    /// Polls start at the first and double to the last, resetting whenever the take changes.
    public static let firstPollSeconds = 2
    public static let maxPollSeconds = 15

    public enum Outcome: Sendable, Equatable {
        case done(VoiceTake)
        case failed(VoiceTake)
        /// The server refused something no retry will change (a 4xx), or wants audio this device
        /// does not have. The take stays owed; the next resume tries again.
        case stuck(String)
        case cancelled
    }

    public static func resolve(
        takeId: String, seal: VoiceTakeSeal, sampleRate: Int, recordedSamples: Int, api: any VoiceTakeAPI,
        audioReader: any TakeAudioReader, sleep: @Sendable (Duration) async -> Void,
        onTake: @Sendable (VoiceTake) async -> Void = { _ in }
    ) async -> Outcome {
        var pollSeconds = firstPollSeconds
        var take: VoiceTake?
        while !Task.isCancelled {
            let current: VoiceTake
            if let take {
                current = take
            } else {
                do {
                    current = try await sealOrRead(takeId: takeId, seal: seal, api: api)
                } catch {
                    if let refused = refusal(error) { return .stuck(refused) }
                    await sleep(.seconds(pollSeconds))
                    pollSeconds = min(pollSeconds * 2, maxPollSeconds)
                    continue
                }
                await onTake(current)
            }
            if current.state == .done { return .done(current) }

            // A failed take still takes audio — a fresh upload returns it to `sealed` — so a
            // device that comes back after the server gave up on it still delivers what it holds.
            if !current.missing.isEmpty {
                guard current.missing.allSatisfy({ $0.upperBound <= recordedSamples }) else {
                    return .stuck("the server is missing audio this device does not have")
                }
                switch await upload(
                    current.missing, takeId: takeId, sampleRate: sampleRate, api: api, audioReader: audioReader)
                {
                case let .uploaded(updated):
                    take = updated
                    await onTake(updated)
                    pollSeconds = firstPollSeconds
                case let .refused(reason):
                    return .stuck(reason)
                case .retryLater:
                    // Uploads are idempotent by range, so the same list is simply sent again.
                    take = current
                    await sleep(.seconds(pollSeconds))
                    pollSeconds = min(pollSeconds * 2, maxPollSeconds)
                }
                continue
            }
            if current.state == .failed { return .failed(current) }

            await sleep(.seconds(pollSeconds))
            guard !Task.isCancelled else { break }
            do {
                let refreshed = try await api.getVoiceTake(takeId: takeId)
                if refreshed.state != current.state || refreshed.missing != current.missing {
                    pollSeconds = firstPollSeconds
                    await onTake(refreshed)
                } else {
                    pollSeconds = min(pollSeconds * 2, maxPollSeconds)
                }
                take = refreshed
            } catch {
                if let refused = refusal(error) { return .stuck(refused) }
                pollSeconds = min(pollSeconds * 2, maxPollSeconds)
            }
        }
        return .cancelled
    }

    public enum UploadResult: Sendable, Equatable {
        /// Every range went up; the take as the last upload left it.
        case uploaded(VoiceTake)
        case refused(String)
        /// A transport error, a 5xx, or a take the server does not know yet: try again later.
        case retryLater
    }

    /// Uploads `ranges` from the take's recording in pieces of at most ``uploadPieceSeconds``.
    /// Stops at the first failure: what landed is stored either way, and the next pass asks the
    /// server what is still missing rather than trusting a list from before the failure.
    public static func upload(
        _ ranges: [SampleRange], takeId: String, sampleRate: Int, api: any VoiceTakeAPI,
        audioReader: any TakeAudioReader, device: String? = nil
    ) async -> UploadResult {
        var last: VoiceTake?
        for piece in pieces(of: ranges, sampleRate: sampleRate) {
            guard !Task.isCancelled else { return .retryLater }
            let pcm: Data
            do {
                pcm = try await audioReader.readSamples(id: takeId, range: WavByteRange.forSamples(piece))
            } catch {
                return .refused("could not read the recording: \(error)")
            }
            guard pcm.count == piece.count * 2 else { return .refused("the recording is shorter than the take") }
            let wav = PcmWavWriter.wrap(pcm16le: PcmWavWriter.samples(fromPCM16LE: pcm), sampleRate: sampleRate)
            do {
                last = try await api.uploadVoiceTakeAudio(takeId: takeId, range: piece, wav: wav, device: device)
            } catch {
                if let refused = refusal(error) { return .refused(refused) }
                return .retryLater
            }
        }
        guard let last else { return .retryLater }
        return .uploaded(last)
    }

    /// `ranges` cut into upload pieces, in order.
    public static func pieces(of ranges: [SampleRange], sampleRate: Int) -> [SampleRange] {
        let maxSamples = max(1, uploadPieceSeconds * sampleRate)
        return TranscriptLedger.merge(ranges).flatMap { range -> [SampleRange] in
            stride(from: range.lowerBound, to: range.upperBound, by: maxSamples).map {
                $0..<min($0 + maxSamples, range.upperBound)
            }
        }
    }

    /// A seal is idempotent; one that contradicts the server's (the server sealed an untouched
    /// take itself) is answered 409, and the server's own record then decides what is missing.
    private static func sealOrRead(takeId: String, seal: VoiceTakeSeal, api: any VoiceTakeAPI) async throws
        -> VoiceTake
    {
        do {
            return try await api.sealVoiceTake(takeId: takeId, seal: seal)
        } catch let error as PaiError where error.statusCode == 409 {
            return try await api.getVoiceTake(takeId: takeId)
        }
    }

    /// The reason to stop for an error no retry fixes, or `nil` for one that clears by itself.
    /// A 409 is not one: it means the take moved on (`take_done`), which the next read shows.
    private static func refusal(_ error: Error) -> String? {
        guard let paiError = error as? PaiError, paiError.statusCode != 409, paiError.isPermanentRejection else {
            return nil
        }
        return paiError.userMessage
    }
}

extension PaiError {
    /// The HTTP status the server answered with, `nil` for a failure that never got one.
    public var statusCode: Int? {
        switch self {
        case let .detail(_, statusCode), let .http(statusCode, _): statusCode
        case .transport, .decoding: nil
        }
    }
}

/// Where a take's words sit in the composer at the press of Send — what a held send carries as
/// `before` and `after`, so the server can put the take's final text exactly where its partial
/// text was. Strings cross the wire, never offsets.
public enum HeldTakeSplit {
    /// `insertedText` is the take's own words as this device wrote them (`stt-rec: ` included);
    /// `nil` for a batch take, which writes nothing while it records, so its text goes after
    /// everything typed. `nil` when the take's words are no longer in the composer — edited or
    /// deleted — and the send is then an ordinary one: nothing typed is ever dropped to make
    /// room for the take.
    public static func split(composerText: String, insertedText: String?) -> (before: String, after: String)? {
        guard let insertedText else {
            return (composerText.trimmingCharacters(in: .whitespacesAndNewlines), "")
        }
        guard !insertedText.isEmpty, let range = composerText.range(of: insertedText, options: .backwards) else {
            return nil
        }
        let before = String(composerText[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let after = String(composerText[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (before, after)
    }
}

/// Applies a finished take's text — authoritative for the whole take — to the draft it was
/// dictated into, as `docs/VOICE_PROTOCOL.md` "Takes" lays down for every client: nothing when
/// the draft already holds exactly those words, the take's own earlier words replaced where they
/// can still be found, appended where they cannot. Unlike ``DraftHeal``, which only ever replaces,
/// this one appends: the server's text is the only copy of words this device never showed, and
/// leaving them out loses them.
public enum TakeResultHeal {
    /// `nil` means leave the draft as it is.
    public static func apply(currentDraftText: String, previousInsertedText: String?, takeText: String) -> String? {
        let text = takeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let healed = "\(VoiceRecordingResult.sttPrefix)\(text)"
        if currentDraftText.contains(healed) { return nil }
        if let previousInsertedText,
            case let .replaced(updated) = DraftHeal.heal(
                currentDraftText: currentDraftText, previousInsertedText: previousInsertedText, healedText: healed)
        {
            return updated
        }
        return currentDraftText.isEmpty ? healed : "\(currentDraftText) \(healed)"
    }
}

/// One owed take as a composer sees it: which draft it belongs to and what this device holds
/// about it.
public struct OwedTakeSummary: Sendable, Equatable {
    public let takeId: String
    public let draftKey: String?
    public let serverTake: PendingServerTake

    public init(takeId: String, draftKey: String?, serverTake: PendingServerTake) {
        self.takeId = takeId
        self.draftKey = draftKey
        self.serverTake = serverTake
    }

    /// A batch take on its way: the server is transcribing it, or will once this device's
    /// uploads land.
    public var isTranscribing: Bool { serverTake.mode == .batch && serverTake.stuckReason == nil }

    /// The take a Send in `draftKey`'s composer should wait on, if any: the newest owed take of
    /// that draft that no send carries yet, is not stuck, and whose words the message would contain — a batch
    /// take's always (they are added after everything typed), a live take's only while its words
    /// are still in the composer. A take whose words were deleted or edited away is not waited
    /// on; its result comes back into the draft instead.
    public static func heldSendCandidate(
        among owed: [OwedTakeSummary], draftKey: String, composerText: String
    ) -> OwedTakeSummary? {
        owed
            .filter { summary in
                let take = summary.serverTake
                guard summary.draftKey == draftKey, !take.standalone, take.isOwed, take.heldClientMessageId == nil,
                    take.stuckReason == nil
                else { return false }
                switch take.mode {
                case .batch: return true
                case .live, .unrecognized:
                    guard let inserted = take.insertedText, !inserted.isEmpty else { return false }
                    return composerText.contains(inserted)
                }
            }
            .max { (Int($0.takeId) ?? 0) < (Int($1.takeId) ?? 0) }
    }
}
