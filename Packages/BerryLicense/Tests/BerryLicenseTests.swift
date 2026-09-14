import CryptoKit
import Foundation
import Testing

@testable import BerryLicense

@Suite("BerryLicense (M5)")
struct BerryLicenseTests {
    // A real license blob signed by berrydb-backend's built-in dev key, plus
 // that key — proves Rust-signs / Swift-verifies interop.
    static let realToken =
        "eyJwbGFuIjoicHJvIiwiZW1haWwiOiJkZXZAYmVycnlkYi5sb2NhbCIsImRldmljZV9oYXNoIjoic21va2UtZGV2aWNlIiwiZXhwIjoxODE1NzQ2NzQ3LCJpc3N1ZWRfYXQiOjE3ODQyMTA3NDgsImZhbGxiYWNrX3ZlciI6IjEuMCJ9.rCNmLF6Rtcndk9lMmHnX0qcjNrWZpjPjVMBGDBD1rQpnlPafc5mYlcVAlms2O8bQ36TKG_Xh06r_cu_shKB_AQ"

    private func devPublicKey() throws -> Curve25519.Signing.PublicKey {
        try LicenseManager.publicKey(fromBase64: LicenseManager.devPublicKeyBase64)
    }

    @Test func verifiesRealBackendSignedToken() throws {
        let payload = try LicenseBlob.verify(Self.realToken, publicKey: devPublicKey())
        #expect(payload.plan == "pro")
        #expect(payload.email == "dev@berrydb.local")
        #expect(payload.deviceHash == "smoke-device")
        #expect(payload.fallbackVer == "1.0")
    }

    @Test func rejectsTamperedPayload() throws {
        // Flip a character in the payload segment; signature no longer matches.
        var chars = Array(Self.realToken)
        chars[5] = chars[5] == "A" ? "B" : "A"
        let tampered = String(chars)
        #expect(throws: (any Error).self) {
            try LicenseBlob.verify(tampered, publicKey: devPublicKey())
        }
    }

    @Test func rejectsWrongKey() throws {
        let other = Curve25519.Signing.PrivateKey().publicKey
        #expect(throws: LicenseVerifyError.badSignature) {
            try LicenseBlob.verify(Self.realToken, publicKey: other)
        }
    }

    @Test func rejectsMalformed() throws {
        #expect(throws: LicenseVerifyError.malformed) {
            try LicenseBlob.verify("no-dot-here", publicKey: devPublicKey())
        }
    }

    @Test func swiftRoundTripValidatesVerifyPath() throws {
        // Independent of the backend: sign with a Swift key and verify.
        let key = Curve25519.Signing.PrivateKey()
        let json = Data(#"{"plan":"pro","email":"a@b.c","device_hash":"d","exp":1,"issued_at":0,"fallback_ver":"1.0"}"#.utf8)
        let sig = try key.signature(for: json)
        let token = base64url(json) + "." + base64url(sig)
        let payload = try LicenseBlob.verify(token, publicKey: key.publicKey)
        #expect(payload.email == "a@b.c")
    }

    // MARK: - Status state machine

    private func payload(plan: String, exp: Int64, fallback: String = "1.0") -> LicensePayload {
        LicensePayload(plan: plan, email: "e", deviceHash: "d", exp: exp, issuedAt: 0, fallbackVer: fallback)
    }

    @Test func statusActiveGraceFallback() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Active: 10 days out.
        #expect(LicenseManager.status(for: payload(plan: "pro", exp: 1_000_000 + 10 * 86_400), now: now)
            == .active(plan: "pro", daysLeft: 10))
        // Grace: 5 days past expiry (≤14).
        #expect(LicenseManager.status(for: payload(plan: "pro", exp: 1_000_000 - 5 * 86_400), now: now)
            == .grace(plan: "pro", daysOver: 5))
        // Fallback: 20 days past expiry (>14).
        #expect(LicenseManager.status(for: payload(plan: "pro", exp: 1_000_000 - 20 * 86_400, fallback: "1.0"), now: now)
            == .fallback(version: "1.0"))
    }

    @Test func statusTrialAndExpiredTrial() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(LicenseManager.status(for: payload(plan: "trial", exp: 1_000_000 + 3 * 86_400), now: now)
            == .trial(daysLeft: 3))
        // Expired trial drops straight to trialExpired (no grace for trials,
        // and distinct from .fallback so the UI doesn't call it "Fallback mode").
        #expect(LicenseManager.status(for: payload(plan: "trial", exp: 1_000_000 - 86_400), now: now)
            == .trialExpired(version: "1.0"))
    }

    @Test func statusNoneWhenNoPayload() {
        #expect(LicenseManager.status(for: nil) == .none)
        #expect(!LicenseStatus.none.isEntitled)
        #expect(LicenseStatus.active(plan: "pro", daysLeft: 1).isEntitled)
        #expect(!LicenseStatus.fallback(version: "1.0").isEntitled)
        #expect(!LicenseStatus.trialExpired(version: "1.0").isEntitled)
    }

    // MARK: - Tier entitlements (Q15 gating removed — every feature unconditional)

    /// Q15's original tier split (trial unlocks all; paid defers to blob
    /// `entitlements`; `none`/`fallback`/`trialExpired` unlock nothing) is
    /// deliberately gone — a considered product decision, not a bug. Every
    /// status/entitlements combination now unlocks every feature, including
    /// no license installed at all.
    @Test func everyStatusAndEntitlementCombinationUnlocksEveryFeature() {
        let cases: [(LicenseStatus, [String])] = [
            (.trial(daysLeft: 5), []),
            (.active(plan: "pro", daysLeft: 30), ["ai", "intelligence"]),
            (.active(plan: "pro", daysLeft: 30), ["ai"]), // paid, entitlement absent — still unlocked
            (.grace(plan: "pro", daysOver: 2), ["intelligence"]),
            (.none, []),
            (.none, ["intelligence"]),
            (.fallback(version: "1.0"), ["intelligence"]),
            (.trialExpired(version: "1.0"), ["intelligence"]),
        ]
        for (status, entitlements) in cases {
            #expect(LicenseManager.hasFeature(LicenseFeature.intelligence, status: status, entitlements: entitlements))
        }
    }

    @Test func payloadDecodesEntitlementsAndDefaultsEmpty() throws {
        let with = Data(#"{"plan":"pro","email":"a@b.c","device_hash":"d","exp":1,"issued_at":0,"fallback_ver":"1.0","entitlements":["ai","intelligence"]}"#.utf8)
        #expect(try JSONDecoder().decode(LicensePayload.self, from: with).entitlements == ["ai", "intelligence"])
        // Pre-Q15 blob without the field → empty, still decodes.
        let without = Data(#"{"plan":"pro","email":"a@b.c","device_hash":"d","exp":1,"issued_at":0,"fallback_ver":"1.0"}"#.utf8)
        #expect(try JSONDecoder().decode(LicensePayload.self, from: without).entitlements.isEmpty)
    }

    @Test func refreshTriggersOnlyNearExpiry() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = LicenseManager.refreshWindow // 3 days
        // Comfortably valid (10 days out) → no refresh.
        #expect(!LicenseManager.shouldRefresh(exp: 1_000_000 + 10 * 86_400, window: window, now: now))
        // Inside the window (2 days out) → refresh.
        #expect(LicenseManager.shouldRefresh(exp: 1_000_000 + 2 * 86_400, window: window, now: now))
        // Already expired → refresh.
        #expect(LicenseManager.shouldRefresh(exp: 1_000_000 - 86_400, window: window, now: now))
    }

    // MARK: - Revocation (a `refreshNow()` failure must not silently leave a
 // revoked license showing "active")

    @Test func planRequiredIsADefinitiveRejection() {
        #expect(LicenseManager.isDefinitiveRejection(APIError(code: "plan_required", message: "")))
    }

    @Test func otherErrorCodesAreNotDefinitiveRejections() {
        // A refresh can fail for reasons that must NOT clear a valid cached
        // license — e.g. a transient backend error, or any code other than
        // the one `/v1/licenses/refresh` documents for an unknown/revoked
        // token. Only "offline" (a transport failure, never even reaching
        // this decision) and "plan_required" are meaningfully distinguished;
        // everything else defaults to "don't clear."
        #expect(!LicenseManager.isDefinitiveRejection(APIError(code: "rate_limited", message: "")))
        #expect(!LicenseManager.isDefinitiveRejection(APIError(code: "internal_error", message: "")))
    }

    // MARK: - base64url

    @Test func base64URLDecodeHandlesMissingPadding() {
        // "test" → base64url "dGVzdA" (no padding) must still decode.
        #expect(LicenseBlob.base64URLDecode("dGVzdA") == Data("test".utf8))
    }

    // MARK: - LicenseClientError (a network failure must not surface as
    // Foundation's raw NSError fallback — reported: "The operation couldn't
    // be completed. BerryLicense.LicenseClientError error 0.")

    @Test func transportAndBadResponseDescribeAsTheirBareCode() {
        // `LicenseManager` treats `error.localizedDescription` as a code to
        // look up (mirroring `APIError.code`) and hands it to
        // `licenseErrorMessage`, which matches on these exact strings — not
        // conforming to LocalizedError here silently breaks that mapping.
        #expect(LicenseClientError.transport.localizedDescription == "transport")
        #expect(LicenseClientError.badResponse.localizedDescription == "badResponse")
    }

    // MARK: - DeviceID

    @Test func deviceHashIsStableAndSaltSensitive() {
        let a1 = DeviceID.deviceHash(salt: "a")
        let a2 = DeviceID.deviceHash(salt: "a")
        let b = DeviceID.deviceHash(salt: "b")
        #expect(a1 == a2)
        #expect(a1 != b)
    }

    private func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
