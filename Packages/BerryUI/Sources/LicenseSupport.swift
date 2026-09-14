import BerryLicense
import Foundation
import SwiftUI

extension LicenseManager {
    nonisolated static let defaultBackend = "http://127.0.0.1:8787"

    /// Backend root for license + AI gateway (`BERRYDB_BACKEND_URL`, default
 /// local staging on:8787). Both services share one host.
    nonisolated static func backendURL() -> URL {
        if let envURL = ProcessInfo.processInfo.environment["BERRYDB_BACKEND_URL"], !envURL.isEmpty {
            return secureBackendURL(envURL)
        }
        if let plistURL = Bundle.main.object(forInfoDictionaryKey: "BERRYDB_BACKEND_URL") as? String, !plistURL.isEmpty {
            return secureBackendURL(plistURL)
        }
        return secureBackendURL(defaultBackend)
    }

    /// The bearer token (license + AI) rides `Authorization` on every backend
 /// call, so a plaintext remote host would leak it. Guard: allow
    /// https anywhere, or http only on loopback (dev); a misconfigured
    /// non-loopback `http://` URL fails safe to the local default rather than
    /// sending the token in cleartext.
    nonisolated static func secureBackendURL(_ raw: String) -> URL {
        let fallback = URL(string: defaultBackend)!
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return fallback }
        if scheme == "https" { return url }
        if scheme == "http", isLoopback(url.host) { return url }
        return fallback
    }

    nonisolated private static func isLoopback(_ host: String?) -> Bool {
        guard let host else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// Signature-verification key (`BERRYDB_LICENSE_PUBLIC_KEY`) — must match
    /// whatever `BERRYDB_LICENSE_SEED` the target backend signs with (fetch
    /// the current value from `GET /v1/license-public-key`, not a secret).
    /// Falls back to the built-in dev key, which matches the local backend's
    /// own fallback when its `BERRYDB_LICENSE_SEED` is unset — so this only
    /// needs setting alongside `BERRYDB_BACKEND_URL` when pointing elsewhere.
    ///
    /// Checks Info.plist same as `backendURL()`, not just the environment —
    /// a Finder-launched, notarized `.app` never inherits the shell env a
    /// dev sets in `.env`/`deploy/.env`, so an env-only lookup silently fell
    /// back to the dev key for every real distributed build (the dev key
    /// doesn't match production's real signing key), breaking activation/
    /// trial/top-up client-side signature verification for every real user.
    /// `scripts/make_app.sh` embeds it into Info.plist when set.
    nonisolated static func publicKeyBase64() -> String {
        if let envKey = ProcessInfo.processInfo.environment["BERRYDB_LICENSE_PUBLIC_KEY"], !envKey.isEmpty {
            return envKey
        }
        if let plistKey = Bundle.main.object(forInfoDictionaryKey: "BERRYDB_LICENSE_PUBLIC_KEY") as? String, !plistKey.isEmpty {
            return plistKey
        }
        return devPublicKeyBase64
    }

    /// Builds the app's license manager against the configured backend.
    @MainActor
    static func makeDefault() -> LicenseManager {
        LicenseManager(client: LicenseClient(baseURL: backendURL()), publicKeyBase64: publicKeyBase64())
    }
}

extension LicenseStatus {
    /// Short label for the toolbar badge.
    var shortLabel: String {
        switch self {
        case .none: String(localized: "Unlicensed", bundle: berryModuleBundle)
        case .trial(let days): String(localized: "Trial · \(days)d", bundle: berryModuleBundle)
 // "topup" (gap-fix): a device's token in place of the trial
        // plan once it buys AI credit — not a subscription tier, so
        // "Topup".capitalized would read oddly here.
        case .active(let plan, _): plan == "topup" ? String(localized: "Credit", bundle: berryModuleBundle) : plan.capitalized
        case .grace: String(localized: "Renew", bundle: berryModuleBundle)
        case .trialExpired: String(localized: "Trial ended", bundle: berryModuleBundle)
        case .fallback: String(localized: "Fallback", bundle: berryModuleBundle)
        }
    }

    var systemImage: String {
        switch self {
        case .none: "person.crop.circle.badge.questionmark"
        case .trial: "clock.badge"
        case .active: "checkmark.seal.fill"
        case .grace: "exclamationmark.triangle"
        case .trialExpired: "clock.badge.exclamationmark"
        case .fallback: "lock.slash"
        }
    }

    var tint: Color {
        switch self {
        case .none: .secondary
        case .trial: .blue
        case .active: .green
        case .grace: .orange
        case .trialExpired, .fallback: .red
        }
    }
}

/// Maps a stable backend error code (or a raw message) to a localized string
/// (client renders by code).
func licenseErrorMessage(_ code: String) -> String {
    switch code {
    case "unknown_key": String(localized: "License key not found", bundle: berryModuleBundle)
    case "device_limit":
        String(localized: "This license is already active on the maximum number of devices", bundle: berryModuleBundle)
    case "expired": String(localized: "This license has expired", bundle: berryModuleBundle)
    case "plan_required": String(localized: "Sign in required", bundle: berryModuleBundle)
    case "key_sent":
        String(localized: "We sent your license key to your purchase email — check your inbox and enter it above to activate.", bundle: berryModuleBundle)
    case "no_subscription":
        String(localized: "No subscription was found for that email or device yet.", bundle: berryModuleBundle)
    case "trial_already_used":
        String(localized: "This device has already used its free trial with a different account. Sign in with that account, or use a license key.", bundle: berryModuleBundle)
    case "transport", "badResponse":
        String(localized: "Could not reach the license server", bundle: berryModuleBundle)
    case "license_verify_malformed", "license_verify_bad_base64", "license_verify_bad_payload":
        String(localized: "This license could not be read — it may be corrupted. Try activating again with your key or restoring by email.", bundle: berryModuleBundle)
    case "license_verify_bad_signature":
        String(localized: "This license was signed with a key this app doesn't recognize — it may have been issued for a different environment. Try activating again, or contact support if this keeps happening.", bundle: berryModuleBundle)
    default: code
    }
}
