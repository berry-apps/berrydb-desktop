import CryptoKit
import Foundation
import Security

/// The HMAC key that seals MCP access settings (spec §8.4).
///
/// Lives in Keychain next to connection secrets so only BerryDB-signed
/// binaries can read it. Only the app creates it; the helper calls `load()`
/// and treats a missing key as "no live reads".
public struct MCPAccessKeyStore: Sendable {
    /// Failure modes for loading or storing the access key.
    public enum KeyError: Error, Equatable {
        /// The stored item exists but is not a 32-byte key.
        case invalidStoredKey
        /// The Keychain refused the write; any previously stored key is untouched.
        case keychainWriteFailed
        /// The Keychain refused to answer the read. `loadOrCreate` must not
        /// treat this as "no key" and mint a replacement.
        case keychainReadFailed(OSStatus)
    }

    static let service = "dev.berrydb.mcp.access-key"
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

    /// Wired to the real Keychain, scoped by both `service` and `account` so
    /// this key cannot be confused with a connection secret.
    public static let keychain = MCPAccessKeyStore(
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
    /// Only creates a key when the item is genuinely absent; any other read
    /// failure propagates instead of silently minting a replacement key.
    public func loadOrCreate() throws -> SymmetricKey {
        if let data = try read() {
            guard data.count == Self.keyByteCount else { throw KeyError.invalidStoredKey }
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        guard write(key.withUnsafeBytes { Data($0) }) else { throw KeyError.keychainWriteFailed }
        return key
    }

    /// Helper-side: returns the key if present and well-formed, never creates
    /// one. Any read failure — not found, malformed, or Keychain refusal —
    /// is treated the same way here: no key means no live reads.
    public func load() -> SymmetricKey? {
        guard let data = try? read(), data.count == Self.keyByteCount else { return nil }
        return SymmetricKey(data: data)
    }

    /// Rotation-side: the first step of rotating the key (see `replace(with:)`
    /// for the full order). Distinguishes "no key exists yet" (returns nil —
    /// the legitimate first-rotation state) from a genuine read failure
    /// (throws), so a caller rotating the key never mistakes "the Keychain
    /// refused to answer" for "there is nothing to preserve" and proceeds to
    /// replace a key it never actually read.
    public func loadForRotation() throws -> SymmetricKey? {
        guard let data = try read() else { return nil }
        guard data.count == Self.keyByteCount else { throw KeyError.invalidStoredKey }
        return SymmetricKey(data: data)
    }

    /// Overwrites the stored key. Rotation order (spec §8.4, amended): (1)
    /// `previousKey = try loadForRotation()`, abort on throw; (2) generate
    /// `newKey = SymmetricKey(size: .bits256)`; (3) `replace(with: newKey)`,
    /// abort on throw; (4) `store.saveMCPProject(project, sealingKey: newKey,
    /// previousKey: previousKey)`, or `store.deleteMCPProject(id:sealingKey:
    /// previousKey:)` when the change is a deletion. This call runs *before*
    /// step 4 reseals anything, not after: if step 4 fails or is
    /// interrupted once this call has already succeeded, every row on disk
    /// is still sealed under `previousKey`, which is no longer the stored
    /// key, so live reads stop
    /// for every project until each is individually saved again (that save
    /// reseals its own project's rows from trusted values regardless of
    /// `previousKey`, recovering it immediately). A restored older copy of
    /// the store never verifies under the current key, by the same
    /// mechanism. Throws `keychainWriteFailed` and leaves the previously
    /// stored key untouched if the write fails.
    public func replace(with key: SymmetricKey) throws {
        guard write(key.withUnsafeBytes { Data($0) }) else { throw KeyError.keychainWriteFailed }
    }
}
