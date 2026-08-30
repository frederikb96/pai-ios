import Foundation
import Observation

/// The narrow slice of `PaiApiClient` this store needs.
public protocol MeApiClient: Sendable {
    func getMe() async throws -> MeResponse
}

extension PaiApiClient: MeApiClient {}

/// Who is signed in, fetched once and held for the life of the connection — every session-action
/// route is owner-only (`MeResponse.role`; see `pai-cloud/.claude/CLAUDE.md` "There is one user,
/// and every route is owner-only"), and nothing in the app called `getMe()` before this, so a
/// non-owner credential saw every action and got a 403 back for each one instead of never seeing
/// it at all.
@MainActor
@Observable
public final class MeStore {
    public private(set) var me: MeResponse?
    public private(set) var loadError: String?

    private let api: MeApiClient

    public init(api: MeApiClient) {
        self.api = api
    }

    /// Whether the actions menu's owner-only rows belong on screen. `false` until `refresh()` has
    /// answered — the safe default is to withhold a destructive action rather than flash it
    /// before the identity check lands.
    public var isOwner: Bool { me?.role == .owner }

    public func refresh() async {
        do {
            me = try await api.getMe()
            loadError = nil
        } catch {
            loadError = (error as? PaiError)?.userMessage ?? "Could not confirm who is signed in"
        }
    }
}
