import Foundation

/// What signing out tells the server while the phone still holds its credential: end this
/// sign-in. Best effort and bounded, so a phone without a network still signs out; whatever the
/// server did not hear it forgets once the sign-in's token expires.
public struct ServerSignOut: Sendable {
    public var currentSignInId: @Sendable () async throws -> String?
    public var revokeSignIn: @Sendable (String) async throws -> Void

    public init(
        currentSignInId: @escaping @Sendable () async throws -> String?,
        revokeSignIn: @escaping @Sendable (String) async throws -> Void
    ) {
        self.currentSignInId = currentSignInId
        self.revokeSignIn = revokeSignIn
    }

    public init(api: PaiApiClient) {
        self.init(
            currentSignInId: { try await api.listSignIns().first { $0.current }?.id },
            revokeSignIn: { try await api.revokeSignIn(id: $0) })
    }

    /// Gives up after `timeout` seconds.
    public func run(timeout: TimeInterval) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                if let id = try? await currentSignInId() { try? await revokeSignIn(id) }
            }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }
    }
}
