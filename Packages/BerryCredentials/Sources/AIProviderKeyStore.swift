import Foundation

/// Stores an API key for a user-configured AI provider in Keychain, scoped by
/// the provider's id so it never sits in the database, user defaults, or logs.
/// Only the app writes it; the value is never read back for display.
public struct AIProviderKeyStore: Sendable {
    public enum KeyError: Error, Equatable {
        /// The Keychain refused to answer the read. Callers must not treat
        /// this as "no key" and overwrite it.
        case keychainReadFailed(OSStatus)
        /// The Keychain refused the write; any previously stored key is
        /// untouched.
        case keychainWriteFailed
    }

    static let service = "dev.berrydb.ai.provider-key"

    private let read: @Sendable (String) throws -> Data?
    private let write: @Sendable (String, Data) -> Bool
    private let delete: @Sendable (String) -> Bool

    init(
        read: @escaping @Sendable (String) throws -> Data?,
        write: @escaping @Sendable (String, Data) -> Bool,
        delete: @escaping @Sendable (String) -> Bool
    ) {
        self.read = read
        self.write = write
        self.delete = delete
    }

    /// Wired to the real Keychain, keyed by the provider id as the account so
    /// two providers never share an item.
    public static let keychain = AIProviderKeyStore(
        read: { account in
            do {
                return try KeychainService.readData(service: service, account: account)
            } catch KeychainService.ReadFailure.unexpectedStatus(let status) {
                throw KeyError.keychainReadFailed(status)
            }
        },
        write: { account, data in
            KeychainService.saveData(data, service: service, account: account)
        },
        delete: { account in
            KeychainService.deleteData(service: service, account: account)
        }
    )

    public func save(_ key: String, providerID: UUID) throws {
        guard write(account(for: providerID), Data(key.utf8)) else {
            throw KeyError.keychainWriteFailed
        }
    }

    /// Returns the stored key, or nil when no key has been saved for this
    /// provider. Throws `KeyError.keychainReadFailed` on a Keychain refusal so
    /// the caller can tell "nothing stored yet" apart from "unreadable".
    public func read(providerID: UUID) throws -> String? {
        guard let data = try read(account(for: providerID)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete(providerID: UUID) {
        _ = delete(account(for: providerID))
    }

    private func account(for providerID: UUID) -> String {
        providerID.uuidString.lowercased()
    }
}
