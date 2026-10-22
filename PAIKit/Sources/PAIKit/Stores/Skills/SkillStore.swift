import Foundation
import Observation

/// What a skill listing is asked for: an existing session, or the settings a new one would start
/// with. The listing belongs to the environment a session runs in, not to one conversation.
public enum SkillContext: Hashable, Sendable {
    case session(String)
    case newSession(agent: String, sessionType: String, workingDir: String?)

    var queryItems: [URLQueryItem] {
        switch self {
        case .session(let id):
            return [URLQueryItem(name: "session_id", value: id)]
        case .newSession(let agent, let sessionType, let workingDir):
            var items = [
                URLQueryItem(name: "agent", value: agent), URLQueryItem(name: "session_type", value: sessionType),
            ]
            if let workingDir { items.append(URLQueryItem(name: "working_dir", value: workingDir)) }
            return items
        }
    }
}

/// What `SkillStore` needs from the API; `PaiApiClient` conforms structurally.
public protocol SkillApiClient: Sendable {
    func getSkills(for context: SkillContext) async throws -> SkillListing
}

extension PaiApiClient: SkillApiClient {}

extension PaiApiClient {
    /// `GET /api/skills` keyed by session id, or by agent, session type and optional directory.
    public func getSkills(for context: SkillContext) async throws -> SkillListing {
        try await send(path: "/api/skills", query: context.queryItems)
    }
}

/// The skill names each composer context offers, fetched on demand and kept per context.
///
/// A context with no listing yields no names, so every consumer shows nothing rather than
/// guessing; a failed fetch leaves what was cached and is retried by the next `load`.
@MainActor
@Observable
public final class SkillStore {
    /// A cached listing younger than this is not fetched again.
    static let freshFor: TimeInterval = 60

    private var listings: [SkillContext: SkillListing] = [:]
    private var fetchedAt: [SkillContext: Date] = [:]
    private var inFlight: Set<SkillContext> = []

    private let api: any SkillApiClient
    private let now: @Sendable () -> Date

    public init(api: any SkillApiClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api
        self.now = now
    }

    public func names(for context: SkillContext?) -> [String] {
        guard let context else { return [] }
        return listings[context]?.skills.map(\.name) ?? []
    }

    /// Fetches the context's listing unless a fresh one is cached or the same fetch is running.
    public func load(_ context: SkillContext?) async {
        guard let context, !inFlight.contains(context) else { return }
        if let last = fetchedAt[context], now().timeIntervalSince(last) < Self.freshFor { return }
        inFlight.insert(context)
        defer { inFlight.remove(context) }
        guard let listing = try? await api.getSkills(for: context) else { return }
        fetchedAt[context] = now()
        if listings[context] != listing { listings[context] = listing }
    }
}
