import Crypto
import Foundation
@preconcurrency import Citadel
import NIOCore
import NIOSSH

/// Trust-on-first-use store of SSH host-key fingerprints
/// Host public keys are not secret, so this is a plain file like OpenSSH's
/// `known_hosts` — never the Keychain. Keyed by `host:port`.
public struct KnownHostsStore: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Presented key matches the stored one.
        case trusted
        /// No prior record — recorded now and accepted (TOFU first use).
        case recordedFirstUse
        /// A DIFFERENT key than stored — rejected (possible MITM). Not recorded.
        case mismatch(stored: String)
    }

    private let fileURL: URL
    /// Serializes the read-modify-write in `evaluate` across concurrent opens.
    private static let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Default store at Application Support/BerryDB/known_hosts.
    public static func standard() -> KnownHostsStore {
        let base: URL
        if let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("BerryDB", isDirectory: true) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            base = dir
        } else {
            base = URL(fileURLWithPath: NSTemporaryDirectory())
        }
        return KnownHostsStore(fileURL: base.appendingPathComponent("known_hosts"))
    }

    /// OpenSSH-style SHA-256 fingerprint of a host key: `SHA256:<base64>` over
    /// the key's SSH wire encoding.
    public static func fingerprint(of key: NIOSSHPublicKey) -> String {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        _ = key.write(to: &buffer)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        let digest = SHA256.hash(data: Data(bytes))
        let base64 = Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(base64)"
    }

    /// TOFU decision for a presented fingerprint. On first use the fingerprint
    /// is recorded and accepted; a differing fingerprint is rejected WITHOUT
    /// overwriting the trusted one.
    public func evaluate(host: String, port: Int, fingerprint: String) -> Decision {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var entries = readEntries()
        let key = Self.key(host: host, port: port)
        if let stored = entries[key] {
            return stored.fingerprint == fingerprint ? .trusted : .mismatch(stored: stored.fingerprint)
        }
        entries[key] = Entry(host: host, port: port, fingerprint: fingerprint)
        writeEntries(entries)
        return .recordedFirstUse
    }

    /// Overwrites the stored fingerprint — the explicit "trust the changed key"
    /// action after the user confirms the new key out of band.
    public func trust(host: String, port: Int, fingerprint: String) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var entries = readEntries()
        entries[Self.key(host: host, port: port)] = Entry(host: host, port: port, fingerprint: fingerprint)
        writeEntries(entries)
    }

    public func storedFingerprint(host: String, port: Int) -> String? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return readEntries()[Self.key(host: host, port: port)]?.fingerprint
    }

    // MARK: - File format: "host\tport\tfingerprint" per line.

    private struct Entry {
        let host: String
        let port: Int
        let fingerprint: String
    }

    private static func key(host: String, port: Int) -> String { "\(host):\(port)" }

    private func readEntries() -> [String: Entry] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [:] }
        var out: [String: Entry] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let port = Int(parts[1]) else { continue }
            let host = String(parts[0])
            out[Self.key(host: host, port: port)] = Entry(host: host, port: port, fingerprint: String(parts[2]))
        }
        return out
    }

    private func writeEntries(_ entries: [String: Entry]) {
        let text = entries.values
            .sorted { ($0.host, $0.port) < ($1.host, $1.port) }
            .map { "\($0.host)\t\($0.port)\t\($0.fingerprint)" }
            .joined(separator: "\n")
        try? (text + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

/// Citadel host-key delegate implementing TOFU against a `KnownHostsStore`
/// Captures a mismatch so the caller can raise a
/// precise `DriverError.sshHostKeyChanged`.
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let store: KnownHostsStore
    private let host: String
    private let port: Int
    private let lock = NSLock()
    private var capturedMismatch: (stored: String, presented: String)?

    init(store: KnownHostsStore, host: String, port: Int) {
        self.store = store
        self.host = host
        self.port = port
    }

    var mismatch: (stored: String, presented: String)? {
        lock.lock()
        defer { lock.unlock() }
        return capturedMismatch
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = KnownHostsStore.fingerprint(of: hostKey)
        switch store.evaluate(host: host, port: port, fingerprint: presented) {
        case .trusted, .recordedFirstUse:
            validationCompletePromise.succeed(())
        case let .mismatch(stored):
            lock.lock()
            capturedMismatch = (stored, presented)
            lock.unlock()
            validationCompletePromise.fail(HostKeyMismatch())
        }
    }
}

private struct HostKeyMismatch: Error {}
