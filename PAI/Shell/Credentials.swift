import Foundation
import PAIKit
import Security

/// Where the backend credential lives: the token set of a Zitadel sign-in. A pasted token, which
/// earlier versions could store, is never read; `discardLegacyCredential()` removes it.
///
/// The Keychain is the only place on the device holding a secret: the speech-to-text key and the
/// SMTP password are write-only server secrets, posted once and never readable back, so the app
/// knows only whether each is set.
///
/// Not in `PAIKit` because `Security` is Apple-only, and one unguarded import there would drag the
/// whole test suite onto a metered runner.
struct KeychainTokenStore: OidcTokenSetStore {

    #if DEBUG
        /// Fixture mode's token, held in memory because the Keychain is not always available.
        ///
        /// A simulator build made with `CODE_SIGNING_ALLOWED=NO` has no keychain-access-group
        /// entitlement, and `SecItemAdd` refuses with `errSecMissingEntitlement`. A signed build
        /// — every build that reaches a device — is unaffected, so this exists only so the
        /// screenshot workflow can get past the sign-in gate.
        ///
        /// Deliberately not a general fallback: it is consulted only when fixture mode asked for
        /// it, so a real build can never silently keep a credential outside the Keychain.
        nonisolated(unsafe) private static var fixtureToken: String?
        private static let fixtureLock = NSLock()

        /// The status the last fixture-mode write returned, reported by the debug bridge so a
        /// screenshot run says *why* it is sitting on the sign-in screen rather than leaving it
        /// to be guessed at.
        nonisolated(unsafe) private(set) static var lastWriteStatus: OSStatus = errSecSuccess
    #endif

    private let service: String
    private let legacyPastedAccount = "backend-jwt"
    private let legacyMailVerdictKeyAccount = "mailverdict-key"
    private let signInAccount = "oidc-token-set"

    init(service: String = Bundle.main.bundleIdentifier ?? "com.frederikberg.pai") {
        self.service = service
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Explicit, not inherited. This is a work-owned device and a backend credential has no
            // business on the user's other hardware.
            kSecAttrSynchronizable as String: false,
        ]
    }

    /// The bearer every request carries.
    func read() -> String? {
        #if DEBUG
            if PaiFixtureLaunch.isEnabled() {
                Self.fixtureLock.lock()
                defer { Self.fixtureLock.unlock() }
                if let token = Self.fixtureToken { return token }
            }
        #endif
        return readTokenSet().map(\.accessToken).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Signs out: removes the sign-in's token set, and any pasted token an earlier version stored.
    func clear() {
        #if DEBUG
            Self.fixtureLock.lock()
            Self.fixtureToken = nil
            Self.fixtureLock.unlock()
        #endif
        deleteItem(account: signInAccount)
        discardLegacyCredential()
    }

    /// Removes the credentials earlier versions stored beside the sign-in (a pasted token, a
    /// MailVerdict key), so a phone that still holds one asks for a sign-in instead of keeping a
    /// credential nothing reads.
    func discardLegacyCredential() {
        deleteItem(account: legacyPastedAccount)
        deleteItem(account: legacyMailVerdictKeyAccount)
    }

    func readTokenSet() -> OidcTokenSet? {
        readItem(account: signInAccount).flatMap { try? JSONDecoder().decode(OidcTokenSet.self, from: $0) }
    }

    /// A sign-in's tokens, first or renewed.
    @discardableResult
    func writeTokenSet(_ tokens: OidcTokenSet) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        let status = writeItem(account: signInAccount, data: data)
        #if DEBUG
            Self.lastWriteStatus = status
            if status != errSecSuccess, PaiFixtureLaunch.isEnabled() {
                Self.fixtureLock.lock()
                Self.fixtureToken = tokens.accessToken
                Self.fixtureLock.unlock()
                return true
            }
        #endif
        return status == errSecSuccess
    }

    private func readItem(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Delete-then-add rather than `SecItemUpdate`: an update against a missing item fails, and
    /// branching on which case applies is a second code path for no benefit.
    private func writeItem(account: String, data: Data) -> OSStatus {
        deleteItem(account: account)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        // Survives a relaunch and works while the phone is locked but has been unlocked once,
        // which is what a background refresh needs.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil)
    }

    private func deleteItem(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}

/// `UserDefaults` as the package's key-value protocol.
///
/// The package cannot depend on `UserDefaults` — it does not exist on Linux, where the tests run.
extension UserDefaults: @retroactive SettingsKeyValueStore {
    public func data(forKey key: String) -> Data? {
        object(forKey: key) as? Data
    }

    public func setData(_ value: Data?, forKey key: String) {
        set(value, forKey: key)
    }
}
