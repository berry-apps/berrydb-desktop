import BerryDriverKit
import BerryKeyValueKit
import Valkey

/// Redis/Valkey driver — the third contract family,
/// `KeyValueDriver` (BerryKeyValueKit), not `DatabaseDriver`/`DataSourceDriver`.
///
/// `@available(macOS 15, *)`: `valkey-swift`'s own `Package.swift` pins
/// `ValkeyClient` to macOS 15+ (`AvailabilityMacro=valkeySwift 1.0:macOS
/// 15.0, ...`) — a deliberate library minimum that now matches BerryDB's own
/// deployment target. `BerryKeyValueKit` remains independent of `Valkey`.
@available(macOS 15, *)
public struct RedisDriver: KeyValueDriver {
    public static let id: DriverID = .redis
    public static let displayName = "Redis"

 // Capability matrix:
    public static let capabilities = KeyValueCapabilities(
        write: true,
        ttl: true,
        numberedDatabases: true
    )

    public init() {}

    public func connect(_ config: ConnectionConfig) async throws -> any KeyValueConnection {
        try await RedisConnection(config: config)
    }
}
