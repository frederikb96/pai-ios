import Foundation

/// What `POST /api/devices/register` answers with.
///
/// `token` is the server's own normalised form — lowercased and stripped — not necessarily the
/// string that was sent. Two registrations differing only in case or surrounding whitespace
/// collide onto one row, so the value that comes back is the one the backend will actually push
/// to, and the one worth remembering as "already registered".
public struct DeviceRegistration: Codable, Sendable, Equatable {
    public let token: String
    public let registered: Bool
    public let lastSeenAt: String?

    enum CodingKeys: String, CodingKey {
        case token, registered
        case lastSeenAt = "last_seen_at"
    }

    public init(token: String, registered: Bool, lastSeenAt: String?) {
        self.token = token
        self.registered = registered
        self.lastSeenAt = lastSeenAt
    }
}
