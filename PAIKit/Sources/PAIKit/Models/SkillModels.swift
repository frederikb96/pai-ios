import Foundation

/// One skill a session can use, as `GET /api/skills` lists it. The name is exactly what Claude
/// Code lists, plugin prefix included; the description is often empty.
public struct SkillEntry: Codable, Sendable, Equatable {
    public let name: String
    public let description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

/// `GET /api/skills`: an empty list, never an error, when nothing is known for the context.
public struct SkillListing: Codable, Sendable, Equatable {
    public let skills: [SkillEntry]
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case skills
        case updatedAt = "updated_at"
    }

    public init(skills: [SkillEntry], updatedAt: String?) {
        self.skills = skills
        self.updatedAt = updatedAt
    }
}
