import Foundation
import Observation

/// The narrow slice of `PaiApiClient` this store needs — see `/subagents`' guidance on declaring
/// a protocol per consumer rather than mirroring the whole client, matching
/// `ArcSpecListApiClient`'s own shape.
public protocol ArcSpecApiClient: Sendable {
    func getArcSpec(uuid: String) async throws -> ArcSpec
    func getArcRecover(specUuid: String) async throws -> ArcRecoverPayload
}

extension PaiApiClient: ArcSpecApiClient {}

/// One spec's whole timeline, loaded from `GET /api/arc/specs/{uuid}/recover` and re-derived
/// client-side by `ArcTimelineBuilder` — see that type's doc comment for why one call suffices
/// for every segment, not only the active one.
///
/// `@MainActor`, not an actor, matching every other store here: the only realistic caller is a
/// SwiftUI view.
@MainActor
@Observable
public final class ArcSpecStore {
    public let specUuid: String
    private let api: ArcSpecApiClient

    public private(set) var name: String?
    public private(set) var overview: String?
    public private(set) var phase: String?
    public private(set) var timeline: ArcTimeline?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    /// Conversation uuids this spec is bound to — `ArcSubagentLookup.resolveBoundSessionId`'s
    /// own input for a block card's badge tap. Fetched alongside `recover`, since that call
    /// carries no session binding of its own.
    public private(set) var boundSessions: [String] = []

    /// The last `TranscriptStore.ArcSignal.sequence` this store has already acted on, per the
    /// session it was told about — so a caller can pass every live signal it observes and this
    /// store decides for itself whether it is new, rather than every call site having to track
    /// that itself.
    private var lastAppliedSequence: Int?

    public init(specUuid: String, api: ArcSpecApiClient) {
        self.specUuid = specUuid
        self.api = api
    }

    /// `recover` is what draws the screen, so only its own failure fails the whole load. The
    /// spec fetch is best-effort alongside it: losing it only disables the badge → subagent
    /// lookup (`boundSessions` stays empty), never the timeline itself.
    public func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        async let specTask = api.getArcSpec(uuid: specUuid)
        async let recoverTask = api.getArcRecover(specUuid: specUuid)

        let spec = try? await specTask
        do {
            let recover = try await recoverTask
            boundSessions = spec?.sessions ?? []
            apply(recover)
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load this spec"
        }
    }

    /// Reloads without flipping `isLoading` — a live SSE signal or a poll tick should refresh
    /// what is on screen quietly, not show a spinner over a spec someone is already reading.
    public func refreshQuietly() async {
        do {
            apply(try await api.getArcRecover(specUuid: specUuid))
        } catch {
            // A background refresh failing is not worth surfacing over content that is still
            // showing correctly as of the last successful load — the next poll tick or the next
            // pull-to-refresh tries again.
        }
    }

    /// Call with every `TranscriptStore.ArcSignal` observed for the session this spec was
    /// opened from, if any. Refreshes only when the signal is new AND names this spec — a
    /// session can be bound to more than one spec (S24), so an event for a sibling spec must not
    /// trigger a reload here.
    public func applyLiveSignal(_ signal: TranscriptStore.ArcSignal?) {
        guard let signal, signal.specUuid == specUuid, signal.sequence != lastAppliedSequence else { return }
        lastAppliedSequence = signal.sequence
        Task { await refreshQuietly() }
    }

    private func apply(_ payload: ArcRecoverPayload) {
        name = payload.name
        overview = payload.overview
        phase = payload.phase
        timeline = ArcTimelineBuilder.build(
            rows: Array(payload.rows.values), busyAgents: Set(payload.activeSegment.busyAgents)
        )
    }
}

/// Whether a session is running under any ARC spec, and which — the question the session list
/// row swipe and the in-session swipe both ask before offering "Spec" at all.
@MainActor
@Observable
public final class ArcBoundSpecsStore {
    private let api: PaiApiClient

    public init(api: PaiApiClient) {
        self.api = api
    }

    /// `nil` on a fetch failure — read as "unknown, try again", never coerced to "bound to
    /// nothing"; a caller offering a "Spec" action should keep offering it on a failed check
    /// rather than concluding there is nothing there. Empty for a session genuinely bound to
    /// nothing.
    public func boundSpecs(session: String) async -> [ArcSpec]? {
        try? await api.getArcSpecs(session: session)
    }
}
