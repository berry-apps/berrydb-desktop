import Foundation
import Security

/// The single point of Keychain access in the app.
/// Secrets are keyed by profile UUID, live only in RAM after reading, and are
/// never logged or persisted anywhere else.
public enum KeychainService {
    public enum SecretKind: String, CaseIterable, Sendable {
        case database = "db"
        case ssh = "ssh"
        case sshPassphrase = "sshpp"
        /// Elasticsearch API-key auth mode — a real second secret shape, not
        /// another `password`-reuse hack like Qdrant's API key.
        case elasticsearchAPIKey = "esapikey"
    }

    static func service(_ kind: SecretKind, _ profileID: UUID) -> String {
        "dev.berrydb.\(kind.rawValue).\(profileID.uuidString.lowercased())"
    }

    /// A Keychain read that neither found the item nor completed normally.
    /// Kept distinct from "not found" so a caller like `MCPAccessKeyStore`
    /// never treats a real failure (permission denied, locked item, …) as
    /// license to silently create a replacement.
    enum ReadFailure: Error, Equatable {
        case unexpectedStatus(OSStatus)
    }

    @discardableResult
    public static func savePassword(
        _ password: String,
        kind: SecretKind = .database,
        profileID: UUID
    ) -> Bool {
        saveData(Data(password.utf8), service: service(kind, profileID))
    }

    public static func readPassword(
        kind: SecretKind = .database,
        profileID: UUID
    ) -> String? {
        guard let data = try? readData(service: service(kind, profileID)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores raw bytes under `service` (and `account`, when given) with the
    /// attributes every BerryDB secret uses. `account` is nil for every
    /// existing password item; only the MCP access key sets it.
    @discardableResult
    static func saveData(_ data: Data, service: String, account: String? = nil) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
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

    /// Reads raw bytes stored under `service` (and `account`, when given).
    /// Returns nil only when no item is stored; any other outcome throws
    /// `ReadFailure`, so a caller can tell "nothing stored yet" apart from
    /// "the Keychain refused to answer".
    static func readData(service: String, account: String? = nil) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw ReadFailure.unexpectedStatus(status) }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw ReadFailure.unexpectedStatus(status)
        }
    }

    /// Removes the item under `service` (and `account`, when given). Returns
    /// false only when the item is absent; a Keychain refusal to answer is
    /// treated as a delete for the same reason `saveData`'s update path is
    /// idempotent — deleting a secret that is already gone is a success.
    @discardableResult
    static func deleteData(service: String, account: String? = nil) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Deleting a profile must also delete its secrets — no orphaned entries.
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
