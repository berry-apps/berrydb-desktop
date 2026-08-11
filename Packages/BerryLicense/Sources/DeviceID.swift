import CryptoKit
import Foundation
import IOKit

/// Stable, privacy-preserving device identifier (docs/architecture/10 §5).
/// `device_hash = SHA-256(salt ‖ hardware UUID)` — the backend counts devices
/// (≤3, TM-02) without ever seeing the raw machine id.
public enum DeviceID {
    public static let defaultSalt = "berrydb.device.v1"

    public static func deviceHash(salt: String = defaultSalt) -> String {
        let digest = SHA256.hash(data: Data((salt + "\u{1F}" + cachedHardwareUUID).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The hardware UUID can't change while the process is running, so
    /// there's no reason to hit IOKit again on every call — activation
    /// alone calls `deviceHash()` twice (once for the request, once to
    /// verify the response), and it's on the user-facing latency path.
    private static let cachedHardwareUUID: String = hardwareUUID() ?? "unknown-device"

    /// The macOS hardware UUID from the IOPlatformExpertDevice registry entry.
    static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(
            service,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )
        return property?.takeRetainedValue() as? String
    }
}
