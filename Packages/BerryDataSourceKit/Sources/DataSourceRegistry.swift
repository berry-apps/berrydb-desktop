import BerryDriverKit
import Foundation

/// Static registry for the `DataSourceDriver` family — independent from
/// `DriverRegistry` (BerryDriverKit) on purpose: the two protocol families
/// serve different query shapes and must not blur into one union type
/// (docs/architecture/12 §8). `BerryApp` registers at startup, same as
/// `DriverRegistry` — no dynamic loading.
public enum DataSourceRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var drivers: [DriverID: any DataSourceDriver.Type] = [:]

    public static func register(_ driverType: any DataSourceDriver.Type) {
        lock.lock()
        defer { lock.unlock() }
        drivers[driverType.id] = driverType
    }

    public static func driverType(for id: DriverID) -> (any DataSourceDriver.Type)? {
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
