/// What the signed-in person may reach, derived from `/api/me`.
///
/// The backend refuses a route a guest may not use with a 403, so every screen or startup call
/// that would reach one asks here first instead of sending the request and handling the refusal.
/// Each question is named for the thing it admits; the role is never compared at a call site.
///
/// The questions mirror pai-cloud's route gates (owner-only routes call `require_owner`); the
/// web UI's `ownerOnly` apps are the same list. Until `/api/me` has answered, and for a role this
/// build does not know, every owner-only question is `false`: withholding a screen for a moment
/// costs less than a request the server refuses.
public struct Capabilities: Sendable, Equatable {
    /// `nil` until `/api/me` has answered.
    public let role: UserRole?

    public init(role: UserRole?) {
        self.role = role
    }

    public init(me: MeResponse?) {
        self.init(role: me?.role)
    }

    public static let unknown = Capabilities(role: nil)

    /// Whether `/api/me` has answered; what startup waits for before it sends owner-only calls.
    public var isKnown: Bool { role != nil }

    private var isOwner: Bool { role == .owner }

    public var canOpenNotes: Bool { isOwner }
    public var canOpenArc: Bool { isOwner }
    public var canOpenScheduler: Bool { isOwner }
    public var canOpenCanteen: Bool { isOwner }
    public var canOpenDecisions: Bool { isOwner }
    public var canOpenBrowser: Bool { isOwner }

    /// The write-only secrets' presence read (`GET /api/settings/secrets`).
    public var canReadSecrets: Bool { isOwner }

    /// `POST /api/devices/register`: a device token belongs to the owner's account only.
    public var canRegisterPush: Bool { isOwner }
}
