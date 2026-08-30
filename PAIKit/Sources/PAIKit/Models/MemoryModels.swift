import Foundation

/// Swift port of the `MemoryProject`/`MemoryPhase` sections of `pai-cloud/web/src/api/types.ts` —
/// only the fields and routes the "move to project"/"move to phase" pickers need, not the whole
/// memory app (out of scope; see `pai-cloud/.claude/CLAUDE.md` "OUT OF SCOPE").

public struct MemoryProject: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String?
    public let description: String?
    /// `.archived` projects are hidden from pickers, never deleted.
    public let status: String
    public let overviewsEnabled: Bool
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, description, status
        case overviewsEnabled = "overviews_enabled"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: String, name: String?, description: String?, status: String, overviewsEnabled: Bool,
        createdAt: String, updatedAt: String
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.status = status
        self.overviewsEnabled = overviewsEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct MemoryProjectsPage: Codable, Sendable, Equatable {
    public let total: Int
    public let projects: [MemoryProject]

    public init(total: Int, projects: [MemoryProject]) {
        self.total = total
        self.projects = projects
    }
}

public struct MemoryPhase: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let projectId: String
    public let phaseKey: String
    public let name: String?
    public let nameLocked: Bool
    public let summary: String?
    public let turnCount: Int
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case phaseKey = "phase_key"
        case name
        case nameLocked = "name_locked"
        case summary
        case turnCount = "turn_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: String, projectId: String, phaseKey: String, name: String?, nameLocked: Bool, summary: String?,
        turnCount: Int, createdAt: String, updatedAt: String
    ) {
        self.id = id
        self.projectId = projectId
        self.phaseKey = phaseKey
        self.name = name
        self.nameLocked = nameLocked
        self.summary = summary
        self.turnCount = turnCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct MemoryPhasesPage: Codable, Sendable, Equatable {
    public let phases: [MemoryPhase]

    public init(phases: [MemoryPhase]) {
        self.phases = phases
    }
}
