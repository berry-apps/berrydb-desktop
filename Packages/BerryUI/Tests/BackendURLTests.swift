import BerryLicense
import Foundation
import Testing

@testable import BerryUI

/// The bearer token rides Authorization on every backend call, so a plaintext
/// remote host would leak it (docs/architecture/07 §2). `secureBackendURL`
/// fails safe (07 security hardening).
@Suite("Backend URL guard (07 §2)")
struct BackendURLTests {
    @Test func allowsHTTPSAnywhere() {
        #expect(LicenseManager.secureBackendURL("https://api.berrydb.dev").absoluteString
            == "https://api.berrydb.dev")
    }

    @Test func allowsHTTPOnLoopback() {
        for host in ["http://127.0.0.1:8787", "http://localhost:8787", "http://[::1]:8787"] {
            #expect(LicenseManager.secureBackendURL(host).absoluteString == host)
        }
    }

    @Test func rejectsPlaintextRemote() {
        // A misconfigured http:// remote must not receive the token in cleartext;
        // it falls back to the safe local default.
        #expect(LicenseManager.secureBackendURL("http://api.berrydb.dev").absoluteString
            == LicenseManager.defaultBackend)
        #expect(LicenseManager.secureBackendURL("not a url").absoluteString
            == LicenseManager.defaultBackend)
    }
}
