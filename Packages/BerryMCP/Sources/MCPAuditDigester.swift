import BerryCredentials
import Foundation
import Synchronization

/// Turns the audited query of a call into the record's digest under the install key.
public final class MCPAuditDigester: Sendable {
    private let keyStore: MCPAuditKeyStore
    private let diagnostics: @Sendable (String) -> Void
    private let warned = Mutex(false)

    public init(keyStore: MCPAuditKeyStore, diagnostics: @escaping @Sendable (String) -> Void) {
        self.keyStore = keyStore
        self.diagnostics = diagnostics
    }

    /// Reads the key on every call, with no caching: the helper reads its
    /// integrity key from the Keychain on every request as well, and a key the
    /// app creates later must apply to the next call without restarting the
    /// helper. A nil query never touches the key store. Without a key the
    /// record carries no digest, and that is reported once per instance.
    public func digest(_ query: MCPAuditQuery?) -> String? {
        guard let query else { return nil }
        guard let key = keyStore.load() else {
            let first = warned.withLock { warned -> Bool in
                defer { warned = true }
                return !warned
            }
            if first { diagnostics("audit digest key unavailable: records carry no digest") }
            return nil
        }
        return MCPAuditDigest(key: key).digest(query)
    }
}
