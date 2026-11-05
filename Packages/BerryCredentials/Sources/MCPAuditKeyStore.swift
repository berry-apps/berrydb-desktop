import CryptoKit
import Foundation
import Security

/// The HMAC key that keys the query digests in the MCP audit log.
///
/// Kept apart from `MCPAccessKeyStore` because the two have opposite
/// lifetimes. The access key rotates on every save so rows restored from an
/// older store stop verifying. This key must never rotate: digests written
/// months apart have to match for the same query, and a new key would make
/// every earlier record uncorrelatable. That is why there is no rotation or
/// replace API here.
///
/// Only the app creates the key; the helper calls `load()` and leaves digests
/// out when it is missing.
public struct MCPAuditKeyStore: Sendable {
    /// Failure modes for loading or storing the audit key.
    public enum KeyError: Error, Equatable {
        /// The stored item exists but is not a 32-byte key.
        case invalidStoredKey
        /// The Keychain refused the write.
        case keychainWriteFailed
        /// The Keychain refused to answer the read. `loadOrCreate` must not
        /// treat this as "no key" and mint a replacement, which would orphan
        /// every digest written under the existing key.
        case keychainReadFailed(OSStatus)
    }

    static let service = "dev.berrydb.mcp.audit-key"
    /// Scopes this item by account as well as service, so it cannot collide
    /// with a connection secret sharing the `dev.berrydb.*` service namespace.
    static let account = "berrydb.mcp"
    private static let keyByteCount = 32

    private let read: @Sendable () throws -> Data?
    private let write: @Sendable (Data) -> Bool

    init(
        read: @escaping @Sendable () throws -> Data?,
        write: @escaping @Sendable (Data) -> Bool
    ) {
        self.read = read
        self.write = write
    }

    /// Wired to the real Keychain, scoped by both `service` and `account`.
    public static let keychain = MCPAuditKeyStore(
        read: {
            do {
                return try KeychainService.readData(service: service, account: account)
            } catch KeychainService.ReadFailure.unexpectedStatus(let status) {
                throw KeyError.keychainReadFailed(status)
            }
        },
        write: { KeychainService.saveData($0, service: service, account: account) }
    )

    /// App-side: returns the existing key or creates and stores a new one.
    /// Creates only when the item is genuinely absent; any read failure
    /// propagates instead of silently minting a replacement key.
    public func loadOrCreate() throws -> SymmetricKey {
        if let data = try read() {
            guard data.count == Self.keyByteCount else { throw KeyError.invalidStoredKey }
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        guard write(key.withUnsafeBytes { Data($0) }) else { throw KeyError.keychainWriteFailed }
        return key
    }

    /// Helper-side: returns the key when present and 32 bytes long, never
    /// creates one. Not found, malformed and Keychain refusal all mean "no key".
    public func load() -> SymmetricKey? {
        guard let data = try? read(), data.count == Self.keyByteCount else { return nil }
        return SymmetricKey(data: data)
    }
}
