import Foundation

/// `Bundle.module`'s generated accessor traps if it can't find this
/// package's resource bundle in a packaged, signed `.app` — see the same
/// note on `berryModuleBundle` in BerryUI/Sources/Localization.swift, and
/// docs/tests/crash.md for the real crash this caused. Checks the correct
/// packaged-app and dev-run locations first; `.module` itself is only a last
/// resort (in practice, `swift test`, where it's already safe).
private let dataSourceKitModuleBundle: Bundle = {
    let name = "BerryDB_BerryDataSourceKit.bundle"
    if let url = Bundle.main.resourceURL?.appendingPathComponent(name), let bundle = Bundle(url: url) {
        return bundle
    }
    if let bundle = Bundle(url: Bundle.main.bundleURL.appendingPathComponent(name)) {
        return bundle
    }
    return .module
}()

/// `DataSourceDriver`-layer errors — mirrors `DriverError` (BerryDriverKit).
public enum DataSourceError: Error, Sendable {
    case connectionFailed(String)
    case connectionLost(String)
    case queryFailed(String)
    case cancelled
    case notConnected
    case unsupported(String)
}

extension DataSourceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let detail):
            return String(localized: "Connection failed: \(detail)", bundle: dataSourceKitModuleBundle)
        case .connectionLost(let detail):
            return String(localized: "Connection lost: \(detail)", bundle: dataSourceKitModuleBundle)
        case .queryFailed(let message):
            return String(localized: "Query failed: \(message)", bundle: dataSourceKitModuleBundle)
        case .cancelled:
            return String(localized: "Query cancelled", bundle: dataSourceKitModuleBundle)
        case .notConnected:
            return String(localized: "Not connected", bundle: dataSourceKitModuleBundle)
        case .unsupported(let detail):
            return String(localized: "Unsupported: \(detail)", bundle: dataSourceKitModuleBundle)
        }
    }
}
