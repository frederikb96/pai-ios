import Foundation
import PAIKit
import Security

/// Where the backend credential lives: the token set of a Zitadel sign-in, or a pasted token
/// (a machine token, or the way in when signing in is not possible). One at a time; writing either
/// removes the other.
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
    private let pastedAccount = "backend-jwt"
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

    /// The bearer every request carries, whichever way the app is signed in.
    func read() -> String? {
        #if DEBUG
            if PaiFixtureLaunch.isEnabled() {
                Self.fixtureLock.lock()
                defer { Self.fixtureLock.unlock() }
                if let token = Self.fixtureToken { return token }
            }
        #endif
        if let tokens = readTokenSet() { return tokens.accessToken }
        return readItem(account: pastedAccount).flatMap { String(data: $0, encoding: .utf8) }.flatMap {
            $0.isEmpty ? nil : $0
        }
    }

    /// A pasted token. Writing `nil` signs out, removing a sign-in's token set as well.
    @discardableResult
    func write(_ token: String?) -> Bool {
        deleteItem(account: signInAccount)
        guard let token, !token.isEmpty else {
            deleteItem(account: pastedAccount)
            return true
        }
        let status = writeItem(account: pastedAccount, data: Data(token.utf8))
        #if DEBUG
            Self.lastWriteStatus = status
            if status != errSecSuccess, PaiFixtureLaunch.isEnabled() {
                Self.fixtureLock.lock()
                Self.fixtureToken = token
                Self.fixtureLock.unlock()
                return true
            }
        #endif
        return status == errSecSuccess
    }

    func readTokenSet() -> OidcTokenSet? {
        readItem(account: signInAccount).flatMap { try? JSONDecoder().decode(OidcTokenSet.self, from: $0) }
    }

    /// A sign-in's tokens, first or renewed. Replaces a pasted token.
    @discardableResult
    func writeTokenSet(_ tokens: OidcTokenSet) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        deleteItem(account: pastedAccount)
        return writeItem(account: signInAccount, data: data) == errSecSuccess
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

/// The MailVerdict key of this device, for the assistant sessions.
///
/// Kept in the Keychain of this device alone: never synced (not iCloud Keychain, not a backup
/// restored to another phone), never sent to PAI Cloud except as the header of a message to an
/// assistant session, and never part of a queued send. Nothing but Settings writes it.
struct MailVerdictKeyStore {
    private let service: String
    private let account = "mailverdict-key"

    init(service: String = Bundle.main.bundleIdentifier ?? "com.frederikberg.pai") {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    /// Writing `nil` or an empty key removes the item.
    @discardableResult
    func write(_ key: String?) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        guard let key, !key.isEmpty else { return true }
        var query = baseQuery
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
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
