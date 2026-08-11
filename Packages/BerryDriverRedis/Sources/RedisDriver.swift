import BerryDriverKit
import BerryKeyValueKit
import Valkey

/// Redis/Valkey driver (docs/architecture/15) — the third contract family,
/// `KeyValueDriver` (BerryKeyValueKit), not `DatabaseDriver`/`DataSourceDriver`.
///
/// `@available(macOS 15, *)`: `valkey-swift`'s own `Package.swift` pins
/// `ValkeyClient` to macOS 15+ (`AvailabilityMacro=valkeySwift 1.0:macOS
/// 15.0, ...`) — a deliberate library minimum, not something this app can
/// route around. Decision (2026-08-07): keep the app's own minimum at macOS
/// 14 and gate only this driver — the single call site that registers it
/// (`BerryDBApp.swift`) wraps in `if #available(macOS 15, *)`, so on macOS 14
/// nothing ever registers and `.redis` simply never appears in the
/// connection picker. `BerryKeyValueKit` itself has no such gate — it's pure
/// Swift with no dependency on `Valkey`.
@available(macOS 15, *)
public struct RedisDriver: KeyValueDriver {
    public static let id: DriverID = .redis
    public static let displayName = "Redis"

    // Capability matrix: docs/architecture/15 §2.
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
