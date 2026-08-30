import Foundation

/// A kind of push notification, chosen separately on every device.
///
/// The choice is stored as what a device has **muted**, never as what it wants. An opt-in list
/// means a channel added later is silently off for every device already registered and for any
/// client too old to name it; an opt-out list means a new channel arrives switched on and only an
/// explicit mute turns it off. That is both the iOS convention and the forgiving direction to fail
/// in — a notification that arrives unasked is noticed, one that never arrives is not.
///
/// The raw values are the wire contract with `POST /api/devices/register`, and the backend
/// rejects a name it does not know rather than storing it.
public enum PushChannel: String, Codable, Sendable, CaseIterable, Hashable {
    /// An agent with something to say — a session that finished, a question it needs answered.
    case `default`
    /// Monitoring: health alerts, and whatever external systems relay through PAI.
    case alerts

    /// What the settings row is called.
    public var title: String {
        switch self {
        case .default: "Agent notifications"
        case .alerts: "Alerts"
        }
    }

    /// One line under the row, saying what arrives on this channel rather than what it is named.
    public var explanation: String {
        switch self {
        case .default: "A session telling you it finished, or that it needs you."
        case .alerts: "Something in PAI Cloud broke or recovered — the same events that mail you."
        }
    }
}
