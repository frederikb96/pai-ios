#if canImport(Security)
    import Foundation
    import Security

    /// What an extension needs to reach the backend as the signed-in app does.
    public struct SharedCredentials: Codable, Equatable, Sendable {
        public let backendURL: String
        public let token: String

        public init(backendURL: String, token: String) {
            self.backendURL = backendURL
            self.token = token
        }
    }

    /// One Keychain item in an access group the app and its extensions all hold.
    ///
    /// The app stays the owner: it writes this whenever the sign-in or the backend changes, and
    /// an extension only reads. The backend URL rides along because the app keeps it in
    /// `UserDefaults`, which an extension cannot see without an App Group.
    public struct SharedCredentialStore: Sendable {
        /// The `Info.plist` key both targets carry the group under, set from one build setting.
        private static let groupInfoKey = "PAISharedKeychainGroup"

        private let accessGroup: String

        /// `nil` when the bundle names no group, which is a build without the key.
        public init?(bundle: Bundle = .main) {
            guard let group = bundle.object(forInfoDictionaryKey: Self.groupInfoKey) as? String,
                !group.isEmpty
            else { return nil }
            accessGroup = group
        }

        private var baseQuery: [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "shared-credentials",
                kSecAttrAccount as String: "backend",
                kSecAttrAccessGroup as String: accessGroup,
                kSecAttrSynchronizable as String: false,
            ]
        }

        public func read() -> SharedCredentials? {
            var query = baseQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data
            else { return nil }
            return try? JSONDecoder().decode(SharedCredentials.self, from: data)
        }

        /// Writing `nil` removes the item.
        public func write(_ credentials: SharedCredentials?) {
            SecItemDelete(baseQuery as CFDictionary)
            guard let credentials, let data = try? JSONEncoder().encode(credentials) else { return }

            var query = baseQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(query as CFDictionary, nil)
        }
    }
#endif
