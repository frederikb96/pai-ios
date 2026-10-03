import Foundation

/// A backend health alert nobody has acknowledged yet. Mirrors `Alert` in `types.ts`; named
/// `PaiAlert` because `Alert` is SwiftUI's own type.
public struct PaiAlert: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let source: String
    public let key: String
    public let severity: String
    public let message: String
    public let details: [String: PaiJSONValue]?
    /// How many times the same key was raised again while this row stayed open.
    public let count: Int
    public let createdAt: String
    public let lastSeenAt: String

    enum CodingKeys: String, CodingKey {
        case id, source, key, severity, message, details, count
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }

    public init(
        id: String, source: String, key: String, severity: String, message: String,
        details: [String: PaiJSONValue]? = nil, count: Int, createdAt: String, lastSeenAt: String
    ) {
        self.id = id
        self.source = source
        self.key = key
        self.severity = severity
        self.message = message
        self.details = details
        self.count = count
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }
}

/// `GET /api/alerts`: `total` counts every open alert, `alerts` is the newest page of them.
public struct AlertsResponse: Codable, Sendable, Equatable {
    public let total: Int
    public let alerts: [PaiAlert]

    public init(total: Int, alerts: [PaiAlert]) {
        self.total = total
        self.alerts = alerts
    }
}
