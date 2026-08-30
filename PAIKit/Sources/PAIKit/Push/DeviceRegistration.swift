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
    /// The muted channels the backend now holds for this device.
    ///
    /// Optional, and the distinction matters: `nil` is a backend that did not answer about
    /// channels at all, while `[]` is one saying nothing is muted. Recording an absent field as
    /// empty would leave the client's own choice permanently disagreeing with what it believes the
    /// server stores, and re-posting on every launch forever with nothing actually wrong.
    public let mutedChannels: [String]?

    enum CodingKeys: String, CodingKey {
        case token, registered
        case lastSeenAt = "last_seen_at"
        case mutedChannels = "muted_channels"
    }

    public init(token: String, registered: Bool, lastSeenAt: String?, mutedChannels: [String]? = nil) {
        self.token = token
        self.registered = registered
        self.lastSeenAt = lastSeenAt
        self.mutedChannels = mutedChannels
    }
}
