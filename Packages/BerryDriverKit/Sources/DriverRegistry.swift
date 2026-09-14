import Foundation

/// Static driver registry — BerryApp registers at startup, no dynamic
/// loading. This is the ONLY place that knows the
/// list of concrete drivers; core/UI only look them up via DriverID.
public enum DriverRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var drivers: [DriverID: any DatabaseDriver.Type] = [:]

    public static func register(_ driverType: any DatabaseDriver.Type) {
        lock.lock()
        defer { lock.unlock() }
        drivers[driverType.id] = driverType
    }

    public static func driverType(for id: DriverID) -> (any DatabaseDriver.Type)? {
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
