import Foundation
import Security

/// The single point of Keychain access in the app.
/// Secrets are keyed by profile UUID, live only in RAM after reading, and are
/// never logged or persisted anywhere else.
public enum KeychainService {
    public enum SecretKind: String, CaseIterable {
        case database = "db"
        case ssh = "ssh"
        case sshPassphrase = "sshpp"
 /// Elasticsearch API-key auth mode — a real
        /// second secret shape, not another `password`-reuse hack like
        /// Qdrant's API key.
        case elasticsearchAPIKey = "esapikey"
    }

    private static func service(_ kind: SecretKind, _ profileID: UUID) -> String {
        "dev.berrydb.\(kind.rawValue).\(profileID.uuidString.lowercased())"
    }

    @discardableResult
    public static func savePassword(
        _ password: String,
        kind: SecretKind = .database,
        profileID: UUID
    ) -> Bool {
        let service = service(kind, profileID)
        let data = Data(password.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            // Accessible after first unlock: reconnect-on-wake works without
            // prompting, but secrets stay protected before first unlock.
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return updateStatus == errSecSuccess
    }

    public static func readPassword(
        kind: SecretKind = .database,
        profileID: UUID
    ) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(kind, profileID),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Deleting a profile must also delete its secrets — no orphaned entries
 ///
    public static func deleteSecrets(profileID: UUID) {
        for kind in SecretKind.allCases {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service(kind, profileID),
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}

/// Secrets captured by the connection sheet, handed to the single Keychain
/// write point. Empty fields mean "keep stored".
public struct ConnectionSecrets: Sendable {
    public var dbPassword: String?
    public var sshPassword: String?
    public var sshPassphrase: String?
    public var elasticsearchAPIKey: String?

    public init(
        dbPassword: String? = nil, sshPassword: String? = nil, sshPassphrase: String? = nil,
        elasticsearchAPIKey: String? = nil
    ) {
        self.dbPassword = dbPassword
        self.sshPassword = sshPassword
        self.sshPassphrase = sshPassphrase
        self.elasticsearchAPIKey = elasticsearchAPIKey
    }
}
