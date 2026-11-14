import Foundation

/// One of the caller's own sign-ins as `GET /api/sign-ins` lists it; `current` marks the sign-in
/// making the request. Only what sign-out needs.
public struct PaiSignIn: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String
    public let name: String?
    public let active: Bool
    public let current: Bool

    public init(id: String, kind: String, name: String?, active: Bool, current: Bool) {
        self.id = id
        self.kind = kind
        self.name = name
        self.active = active
        self.current = current
    }
}

extension PaiApiClient {

    public func listSignIns() async throws -> [PaiSignIn] {
        try await send(path: "/api/sign-ins")
    }

    /// Ends one sign-in; the current one included, whose next request is then refused with
    /// `device_revoked`.
    public func revokeSignIn(id: String) async throws {
        let _: PaiSignIn = try await send(path: "/api/sign-ins/\(id)/revoke", method: "POST")
    }
}
