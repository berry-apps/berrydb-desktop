import BerryTunnel
import Foundation

/// UI-facing entry point for the SSH known-hosts pin (docs/architecture/07 §4).
/// BerryUI doesn't depend on BerryTunnel directly, so the "trust the changed
/// key" action is exposed here on the standard store.
public enum SSHTrust {
    /// Records the presented host key as trusted — used only after the user
    /// explicitly confirms a changed key out of band.
    public static func trustHostKey(host: String, port: Int, fingerprint: String) {
        KnownHostsStore.standard().trust(host: host, port: port, fingerprint: fingerprint)
    }
}
