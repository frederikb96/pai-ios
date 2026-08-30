import Foundation
import PAIKit
import Security

/// Where the backend JWT lives.
///
/// The Keychain is the only place on the device holding a secret: the speech-to-text key and the
/// SMTP password are write-only server secrets, posted once and never readable back, so the app
/// knows only whether each is set.
///
/// Not in `PAIKit` because `Security` is Apple-only, and one unguarded import there would drag the
/// whole test suite onto a metered runner.
struct KeychainTokenStore {

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
    private let account = "backend-jwt"

    init(service: String = Bundle.main.bundleIdentifier ?? "com.frederikberg.pai") {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Explicit, not inherited. This is a work-owned device and a backend credential has no
            // business on Freddy's other hardware.
            kSecAttrSynchronizable as String: false,
        ]
    }

    func read() -> String? {
        #if DEBUG
            if PaiFixtureLaunch.isEnabled() {
                Self.fixtureLock.lock()
                defer { Self.fixtureLock.unlock() }
                if let token = Self.fixtureToken { return token }
            }
        #endif
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            let token = String(data: data, encoding: .utf8),
            !token.isEmpty
        else {
            return nil
        }
        return token
    }

    /// Writing `nil` removes the item.
    ///
    /// Delete-then-add rather than `SecItemUpdate`: an update against a missing item fails, and
    /// branching on which case applies is a second code path for no benefit.
    @discardableResult
    func write(_ token: String?) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)

        guard let token, !token.isEmpty else { return true }

        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        // Survives a relaunch and works while the phone is locked but has been unlocked once,
        // which is what a background refresh needs.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
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
