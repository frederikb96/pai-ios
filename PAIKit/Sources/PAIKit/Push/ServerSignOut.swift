import Foundation

/// What signing out tells the server while the phone still holds its credential: end this
/// sign-in, which also removes the phone's push token there. Best effort and bounded, so a phone
/// without a network, or a backend that predates the route (404), still signs out; whatever the
/// server did not hear it forgets once the sign-in's token expires.
public struct ServerSignOut: Sendable {
    public var signOutCurrentSignIn: @Sendable () async throws -> Void

    public init(signOutCurrentSignIn: @escaping @Sendable () async throws -> Void) {
        self.signOutCurrentSignIn = signOutCurrentSignIn
    }

    public init(api: PaiApiClient) {
        self.init(signOutCurrentSignIn: { try await api.signOutCurrentSignIn() })
    }

    /// Gives up after `timeout` seconds.
    public func run(timeout: TimeInterval) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await signOutCurrentSignIn() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }
    }
}
