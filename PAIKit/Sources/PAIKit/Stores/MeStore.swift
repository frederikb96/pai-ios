import Foundation
import Observation

/// The narrow slice of `PaiApiClient` this store needs.
public protocol MeApiClient: Sendable {
    func getMe() async throws -> MeResponse
}

extension PaiApiClient: MeApiClient {}

/// Who is signed in, fetched once and held for the life of the connection. Owner-only screens and
/// requests are gated on `capabilities` so a guest never sends the request a 403 would answer.
@MainActor
@Observable
public final class MeStore {
    public private(set) var me: MeResponse?
    public private(set) var loadError: String?

    private let api: MeApiClient
    private var inFlight: Task<Void, Never>?

    /// What the person signed in may reach; `Capabilities.unknown` until `refresh()` has answered.
    public var capabilities: Capabilities { Capabilities(me: me) }

    public init(api: MeApiClient) {
        self.api = api
    }

    /// Whether the actions menu's owner-only rows belong on screen. `false` until `refresh()` has
    /// answered — the safe default is to withhold a destructive action rather than flash it
    /// before the identity check lands.
    public var isOwner: Bool { me?.role == .owner }

    /// Whether a guest is signed in. `false` until `refresh()` has answered: the screens this
    /// hides (alert routing and mail, as on the web) belong to the owner, who is the one who
    /// must not see them flicker away while the identity check lands.
    public var isGuest: Bool { me?.role == .guest }

    /// Reads `/api/me`. A call made while another is in flight waits for that one instead of
    /// sending a second request.
    public func refresh() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { @MainActor in
            do {
                me = try await api.getMe()
                loadError = nil
            } catch {
                loadError = (error as? PaiError)?.userMessage ?? "Could not confirm who is signed in"
            }
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// Returns once the identity is known, or once a read has failed; reads only when no answer
    /// is held. What a caller that must not guess the role awaits.
    public func ensureKnown() async {
        if me == nil { await refresh() }
    }
}
