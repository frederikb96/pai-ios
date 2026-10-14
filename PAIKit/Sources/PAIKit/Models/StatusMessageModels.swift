import Foundation

/// `GET/PUT/DELETE /api/status-message`: free text the backend appends to every scheduled-agent
/// run's prompt.
public struct StatusMessage: Codable, Sendable, Equatable {
    /// The longest text the server accepts; it answers 422 above it.
    public static let maxTextLength = 2000

    /// `nil` when no message is set.
    public let text: String?
    /// After this instant the message is no longer appended. ISO-8601 with an offset.
    public let expiresAt: String?
    /// Computed by the server — text set and not expired. Shown as sent, never recomputed here.
    public let active: Bool
    public let updatedAt: String?

    public init(text: String?, expiresAt: String?, active: Bool, updatedAt: String?) {
        self.text = text
        self.expiresAt = expiresAt
        self.active = active
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case text
        case expiresAt = "expires_at"
        case active
        case updatedAt = "updated_at"
    }
}

/// The `PUT` body. `expires_at` is always written, `null` included: an omitted key would leave
/// room for the server to keep a previous expiry.
public struct StatusMessageUpdate: Encodable, Sendable, Equatable {
    public let text: String
    public let expiresAt: String?

    public init(text: String, expiresAt: String?) {
        self.text = text
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case text
        case expiresAt = "expires_at"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(expiresAt, forKey: .expiresAt)
    }
}
