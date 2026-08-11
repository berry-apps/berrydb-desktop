import BerryDriverKit
import Foundation

/// Static registry for the `KeyValueDriver` family — independent from
/// `DriverRegistry`/`DataSourceRegistry` on purpose, same reasoning as their
/// own separation (docs/architecture/12 §8, 15 §2): each family serves a
/// different query shape and must not blur into one union type. `BerryApp`
/// registers at startup, same as the other two — no dynamic loading.
///
/// Registering `RedisDriver` is gated `if #available(macOS 15, *)` at the
/// call site (docs/architecture/15 §3) — on macOS 14 nothing ever registers,
/// so `registered` stays empty and `.redis` never appears in the connection
/// picker, with no separate visibility flag needed.
public enum KeyValueRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var drivers: [DriverID: any KeyValueDriver.Type] = [:]

    public static func register(_ driverType: any KeyValueDriver.Type) {
        lock.lock()
        defer { lock.unlock() }
        drivers[driverType.id] = driverType
    }

    public static func driverType(for id: DriverID) -> (any KeyValueDriver.Type)? {
        lock.lock()
        defer { lock.unlock() }
        return drivers[id]
    }

    public static var registered: [DriverID] {
        lock.lock()
        defer { lock.unlock() }
        return Array(drivers.keys)
    }
}
