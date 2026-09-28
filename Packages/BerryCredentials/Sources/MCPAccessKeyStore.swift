import CryptoKit
import Foundation

/// The HMAC key that seals MCP access settings (spec §8.4).
///
/// Lives in Keychain next to connection secrets so only BerryDB-signed
/// binaries can read it. Only the app creates it; the helper calls `load()`
/// and treats a missing key as "no live reads".
public struct MCPAccessKeyStore: Sendable {
    public enum KeyError: Error, Equatable {
        case invalidStoredKey
        case keychainWriteFailed
    }

    static let service = "dev.berrydb.mcp.access-key"
    private static let keyByteCount = 32

    private let read: @Sendable () -> Data?
    private let write: @Sendable (Data) -> Bool

    init(read: @escaping @Sendable () -> Data?, write: @escaping @Sendable (Data) -> Bool) {
        self.read = read
        self.write = write
    }

    public static let keychain = MCPAccessKeyStore(
        read: { KeychainService.readData(service: service) },
        write: { KeychainService.saveData($0, service: service) }
    )

    /// App-side: returns the existing key or creates and stores a new one.
    public func loadOrCreate() throws -> SymmetricKey {
        if let data = read() {
            guard data.count == Self.keyByteCount else { throw KeyError.invalidStoredKey }
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        guard write(key.withUnsafeBytes { Data($0) }) else { throw KeyError.keychainWriteFailed }
        return key
    }

    /// Helper-side: returns the key if present and well-formed, never creates one.
    public func load() -> SymmetricKey? {
        guard let data = read(), data.count == Self.keyByteCount else { return nil }
        return SymmetricKey(data: data)
    }
}
