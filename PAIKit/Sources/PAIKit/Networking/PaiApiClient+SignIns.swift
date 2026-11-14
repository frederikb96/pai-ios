import Foundation

extension PaiApiClient {

    /// Ends this device's own sign-in on the backend, which also drops its push token. The
    /// backend identifies the sign-in by the bearer and the device name the request carries.
    public func signOutCurrentSignIn() async throws {
        let _: PaiSignIn = try await send(path: "/api/sign-ins/current/sign-out", method: "POST")
    }
}

/// A sign-in as the backend answers about it; only what sign-out reads back.
public struct PaiSignIn: Codable, Sendable, Equatable {
    public let id: String
    public let active: Bool
}
