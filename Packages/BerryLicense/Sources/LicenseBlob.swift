import CryptoKit
import Foundation

/// The signed license claims. Mirrors the Rust
/// `LicensePayload` in berrydb-backend; field names must match the JSON.
public struct LicensePayload: Codable, Equatable, Sendable {
    public let plan: String
    public let email: String
    public let deviceHash: String
    public let exp: Int64
    public let issuedAt: Int64
    public let fallbackVer: String
    /// Feature flags the plan unlocks — server-driven, so the app never hardcodes
    /// plan→feature mapping (e.g. `["ai", "intelligence"]`, Q15 Tier Intelligence).
    /// Optional in the JSON: blobs issued before Q15 decode to `[]`.
    public let entitlements: [String]

    enum CodingKeys: String, CodingKey {
        case plan, email, exp, entitlements
        case deviceHash = "device_hash"
        case issuedAt = "issued_at"
        case fallbackVer = "fallback_ver"
    }

    public init(
        plan: String, email: String, deviceHash: String,
        exp: Int64, issuedAt: Int64, fallbackVer: String, entitlements: [String] = []
    ) {
        self.plan = plan
        self.email = email
        self.deviceHash = deviceHash
        self.exp = exp
        self.issuedAt = issuedAt
        self.fallbackVer = fallbackVer
        self.entitlements = entitlements
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try c.decode(String.self, forKey: .plan)
        email = try c.decode(String.self, forKey: .email)
        deviceHash = try c.decode(String.self, forKey: .deviceHash)
        exp = try c.decode(Int64.self, forKey: .exp)
        issuedAt = try c.decode(Int64.self, forKey: .issuedAt)
        fallbackVer = try c.decode(String.self, forKey: .fallbackVer)
        entitlements = try c.decodeIfPresent([String].self, forKey: .entitlements) ?? []
    }

    public var expiry: Date { Date(timeIntervalSince1970: TimeInterval(exp)) }
}

public enum LicenseVerifyError: Error, Equatable {
    case malformed
    case badBase64
    case badSignature
    case badPayload
}

/// Offline license verification (principle N4). The blob format is
/// `base64url(payload_json) + "." + base64url(ed25519_signature)`; the
/// signature covers the exact payload bytes, so we verify what we decode — the
/// same contract the Rust backend signs with (berrydb-backend/src/license.rs).
public enum LicenseBlob {
    /// Verifies the signature with the embedded public key and returns claims.
    public static func verify(
        _ token: String,
        publicKey: Curve25519.Signing.PublicKey
    ) throws -> LicensePayload {
        let parts = token.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw LicenseVerifyError.malformed }
        guard let payloadData = base64URLDecode(String(parts[0])) else {
            throw LicenseVerifyError.badBase64
        }
        guard let signature = base64URLDecode(String(parts[1])) else {
            throw LicenseVerifyError.badBase64
        }
        guard publicKey.isValidSignature(signature, for: payloadData) else {
            throw LicenseVerifyError.badSignature
        }
        do {
            return try JSONDecoder().decode(LicensePayload.self, from: payloadData)
        } catch {
            throw LicenseVerifyError.badPayload
        }
    }

    /// Decodes base64url without padding (the format the backend emits).
    static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}
