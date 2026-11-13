/// Where a sign-in's tokens are kept. The app's is the Keychain; the package cannot name it,
/// since `Security` does not exist on Linux.
public protocol OidcTokenSetStore: Sendable {
    /// `nil` when the app is signed in some other way (a pasted token) or not at all.
    func readTokenSet() -> OidcTokenSet?
    /// Whether the write landed.
    @discardableResult func writeTokenSet(_ tokens: OidcTokenSet) -> Bool
}

/// What renewing a refused credential came to.
public enum CredentialRenewal: Equatable, Sendable {
    /// A new access token is stored; the refused request is worth sending again.
    case renewed
    /// The credential is gone for good: no refresh token, or the provider refused it. Sign out.
    case rejected
    /// The provider could not be asked. The credential stays, and the next refusal tries again.
    case unavailable(String)
}

/// Gets a new access token when the backend refuses the current one, once however many requests
/// were refused together.
///
/// Single-flight matters beyond saving round trips: the provider rotates the refresh token, so a
/// second refresh sent with the old one is refused, and that refusal would sign the app out.
/// A refusal of a token that has already been replaced is answered `renewed` without asking
/// anyone, which covers the request that was in flight while another one's renewal finished.
///
/// One per process: two instances would each be single-flight on their own and race each other.
public actor CredentialRenewer {
    private let store: any OidcTokenSetStore
    private let refresh: @Sendable (OidcTokenSet) async throws(OidcError) -> OidcTokenSet
    private let onRenewed: @Sendable () async -> Void
    private var inFlight: Task<CredentialRenewal, Never>?

    /// - Parameter onRenewed: after the new tokens are stored, before any waiting request is
    ///   sent again; where copies of the credential elsewhere (the share extension's) are updated.
    public init(
        store: any OidcTokenSetStore,
        client: OidcTokenClient,
        onRenewed: @escaping @Sendable () async -> Void = {}
    ) {
        self.init(
            store: store,
            refresh: { tokens throws(OidcError) in try await client.refresh(tokens) },
            onRenewed: onRenewed
        )
    }

    init(
        store: any OidcTokenSetStore,
        refresh: @escaping @Sendable (OidcTokenSet) async throws(OidcError) -> OidcTokenSet,
        onRenewed: @escaping @Sendable () async -> Void
    ) {
        self.store = store
        self.refresh = refresh
        self.onRenewed = onRenewed
    }

    /// - Parameter rejectedToken: the access token the refused request carried.
    public func renew(rejecting rejectedToken: String?) async -> CredentialRenewal {
        if let inFlight { return await inFlight.value }
        guard let current = store.readTokenSet() else { return .rejected }
        if current.accessToken != rejectedToken { return .renewed }
        guard current.refreshToken != nil else { return .rejected }

        let task = Task { [store, refresh, onRenewed] () -> CredentialRenewal in
            do throws(OidcError) {
                let renewed = try await refresh(current)
                guard store.writeTokenSet(renewed) else { return .unavailable("could not store the new sign-in") }
                await onRenewed()
                return .renewed
            } catch .rejected {
                return .rejected
            } catch {
                return .unavailable(error.userMessage)
            }
        }
        inFlight = task
        let outcome = await task.value
        inFlight = nil
        return outcome
    }
}
