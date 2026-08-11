import Foundation

/// `Bundle.module`'s generated accessor traps if it can't find this
/// package's resource bundle in a packaged, signed `.app` — see the same
/// note on `berryModuleBundle` in BerryUI/Sources/Localization.swift, and
/// docs/tests/crash.md for the real crash this caused. Checks the correct
/// packaged-app and dev-run locations first; `.module` itself is only a last
/// resort (in practice, `swift test`, where it's already safe).
private let driverKitModuleBundle: Bundle = {
    let name = "BerryDB_BerryDriverKit.bundle"
    if let url = Bundle.main.resourceURL?.appendingPathComponent(name), let bundle = Bundle(url: url) {
        return bundle
    }
    if let bundle = Bundle(url: Bundle.main.bundleURL.appendingPathComponent(name)) {
        return bundle
    }
    return .module
}()

/// Driver-layer errors that can be classified — required by the conformance
/// suite (docs/architecture/05 §7): cancel → `.cancelled`, dropped connection → `.connectionLost`.
///
/// Payload strings are technical detail (often straight from the server, in
/// English); the user-facing wrapper below is localized (UD-06).
public enum DriverError: Error, Sendable {
    case connectionFailed(String)
    case connectionLost(String)
    case queryFailed(message: String, code: Int32?)
    case cancelled
    case notConnected
    case unsupported(String)
    /// The SSH bastion presented a host key different from the one trusted on
    /// first use (docs/architecture/07 §4) — a possible man-in-the-middle. The
    /// connection is refused; the UI offers to trust the new key explicitly.
    case sshHostKeyChanged(host: String, port: Int, stored: String, presented: String)
}

extension DriverError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let detail):
            return String(localized: "Connection failed: \(detail)", bundle: driverKitModuleBundle)
        case .connectionLost(let detail):
            return String(localized: "Connection lost: \(detail)", bundle: driverKitModuleBundle)
        case .queryFailed(let message, let code):
            if let code {
                return String(localized: "Query failed (\(String(code))): \(message)", bundle: driverKitModuleBundle)
            }
            return String(localized: "Query failed: \(message)", bundle: driverKitModuleBundle)
        case .cancelled:
            return String(localized: "Query cancelled", bundle: driverKitModuleBundle)
        case .notConnected:
            return String(localized: "Not connected", bundle: driverKitModuleBundle)
        case .unsupported(let detail):
            return String(localized: "Unsupported: \(detail)", bundle: driverKitModuleBundle)
        case .sshHostKeyChanged(let host, let port, _, _):
            return String(
                localized: "The SSH host key for \(host):\(port) has changed. This could be a man-in-the-middle attack. The connection was refused.",
                bundle: driverKitModuleBundle
            )
        }
    }
}
