import CryptoKit
import Foundation
import Observation

/// License lifecycle state.
public enum LicenseStatus: Equatable, Sendable {
    /// No license installed — running unlicensed.
    case none
    case trial(daysLeft: Int)
    case active(plan: String, daysLeft: Int)
    /// Past expiry but within the 14-day grace window — runs normally, nudges.
    case grace(plan: String, daysOver: Int)
    /// A free trial that ran out (never a paid/admin plan) — same
    /// feature-lockout as `.fallback` but kept as its own case so the UI can
    /// say "your trial ended" instead of the unrelated "Fallback mode"
    /// label, which used to fire here too and read as an error state rather
 /// than an expected, actionable one.
    case trialExpired(version: String)
    /// Past grace on a paid/admin plan — local-only features of `version`, AI off.
    case fallback(version: String)

    /// Whether paid/AI features are unlocked right now.
    public var isEntitled: Bool {
        switch self {
        case .active, .grace, .trial: true
        case .none, .trialExpired, .fallback: false
        }
    }
}

/// Named paid capabilities carried in the license blob's `entitlements`
/// Strings match what berrydb-backend signs.
public enum LicenseFeature {
 /// AI agent.
    public static let ai = "ai"
    /// Database Intelligence — DSG harvest, analyzers, Graph Explorer (Q15).
    public static let intelligence = "intelligence"
}

/// Owns the installed license, verifies it offline (N4), and drives activation
/// against berrydb-backend. `@MainActor @Observable` so the UI reacts to state.
@MainActor
@Observable
public final class LicenseManager {
 /// Grace window after expiry.
    public nonisolated static let graceDays = 14

    /// Dev signing public key from berrydb-backend's built-in seed. Replace
    /// with the production key before shipping (it is logged at backend start).
    public nonisolated static let devPublicKeyBase64 = "QO61pbhIAIDcPXg6qAfoNzLXZWIozEEJ9offnvoc1Xk="

    public private(set) var status: LicenseStatus = .none
    public private(set) var payload: LicensePayload?
    public private(set) var lastError: String?

    private let publicKey: Curve25519.Signing.PublicKey
    private let client: LicenseClient
    private let appVersion: String

    public init(
        client: LicenseClient,
        publicKeyBase64: String = LicenseManager.devPublicKeyBase64,
        appVersion: String = "1.0"
    ) {
        self.client = client
        self.appVersion = appVersion
        self.publicKey = (try? Self.publicKey(fromBase64: publicKeyBase64))
            ?? Curve25519.Signing.PrivateKey().publicKey
        loadInstalled()
    }

    /// Whether the installed license unlocks a named feature.
    ///
    /// Q15's original tier gating (trial unlocks everything; a paid license
    /// deferred to the signed blob's `entitlements`; `none`/`fallback`
    /// unlocked nothing) is deliberately removed — every feature is
    /// unconditionally available regardless of license status, entitlements,
    /// or whether a license is installed at all. This was a considered
    /// product decision (not an oversight): Database Intelligence
    /// (`LicenseFeature.intelligence` — DSG harvest/analyzer/Graph
    /// Explorer/Time Machine) is no longer sold as a separate tier above
    /// "pro"/"ai"; every gate reading this function unlocks together. If
 /// tiered gating is ever reintroduced, ``,
 /// ``, ``, `02`, `13` all documented the old split and would
    /// need the reverse update.
    public func hasFeature(_ feature: String) -> Bool {
        Self.hasFeature(feature, status: status, entitlements: payload?.entitlements ?? [])
    }

    nonisolated static func hasFeature(
        _ feature: String, status: LicenseStatus, entitlements: [String]
    ) -> Bool {
        // Every parameter is ignored — see the doc comment above. The
        // signature stays as-is for source compatibility with the existing
        // call sites and their tests.
        true
    }

    // MARK: - Activation

    public func activate(key: String) async {
        await run { try await self.client.activate(key: key, deviceHash: DeviceID.deviceHash(), appVersion: self.appVersion) }
    }

 /// Restore a Paddle purchase by the email used at checkout — the
    /// fallback when the checkout didn't carry a device hash.
    public func restorePurchase(email: String) async {
        await run { try await self.client.licenseByEmail(email: email, deviceHash: DeviceID.deviceHash()) }
    }

    /// True while `awaitTopup` is polling after opening a Paddle checkout
    /// for AI credit.
    public private(set) var isAwaitingTopup = false

    /// Same reasoning as `beginAwaitingSubscription` — call synchronously
    /// from the "Add Credit" tap handler, before creating the `Task` that
    /// awaits `awaitTopup()`.
    public func beginAwaitingTopup() {
        guard !isAwaitingTopup else { return }
        isAwaitingTopup = true
    }

    /// After opening the topup checkout, poll until the webhook has upgraded
 /// this device's own token (gap-fix: the token
    /// is rewritten in place to carry the paying email and a non-expiring
    /// "topup" plan, not reissued as a new key) — i.e. until `refresh`
    /// reports the "topup" plan. Stops on success, an unexpected error, or
    /// the timeout.
    public func awaitTopup(pollSeconds: UInt64 = 4, maxAttempts: Int = 60) async {
        beginAwaitingTopup()
        defer { isAwaitingTopup = false }
        guard let token = LicenseKeychain.readToken() else { return }
        for attempt in 0..<maxAttempts {
            if Task.isCancelled { return }
            do {
                let response = try await client.refresh(token: token)
                if response.plan == "topup" {
                    let verified = try LicenseBlob.verify(response.license, publicKey: publicKey)
                    guard verified.deviceHash == DeviceID.deviceHash() else { return }
                    try? Self.persist(blob: response.license)
                    LicenseKeychain.saveToken(response.apiToken)
                    payload = verified
                    status = Self.status(for: verified)
                    lastError = nil
                    return
                }
                // Not credited yet — keep waiting (unless this was the last attempt).
                if attempt < maxAttempts - 1 {
                    try? await Task.sleep(nanoseconds: pollSeconds * 1_000_000_000)
                }
            } catch {
                lastError = (error as? APIError)?.code ?? error.localizedDescription
                return
            }
        }
    }

 /// Starts an AI-credit topup: asks the
    /// backend to open a Paddle checkout for `amountCents`. Returns the
    /// checkout URL to open, or nil (with `lastError` set) on failure — e.g.
    /// below the admin-configured minimum (`amount_too_small`).
    public func startTopup(amountCents: Int) async -> URL? {
        // A real installed token only (like `refreshNow`/`awaitTopup`, not
        // `apiToken()`'s "dev-token" fallback) — a topup binds to this
        // specific token's device via the webhook, which the dev-token
        // placeholder has no stable identity to receive.
        guard let token = LicenseKeychain.readToken() else {
            lastError = "plan_required"
            return nil
        }
        lastError = nil
        do {
            let response = try await client.topup(amountCents: amountCents, token: token)
            return URL(string: response.checkoutURL)
        } catch let error as APIError {
            lastError = error.code
            return nil
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    public func startTrial(email: String) async {
        await run { try await self.client.trial(deviceHash: DeviceID.deviceHash(), email: email, appVersion: self.appVersion) }
    }

    /// One-shot: pull a subscription the backend has already granted this device
 /// Covers the case where the post-checkout poll
    /// timed out or the app was reopened after paying — the license shows up
    /// without re-subscribing. Silent when there's nothing yet (no_subscription)
    /// or on transport failure; never downgrades the current status.
    public func syncFromBackend() async {
        do {
            let response = try await client.licenseByDevice(deviceHash: DeviceID.deviceHash())
            let verified = try LicenseBlob.verify(response.license, publicKey: publicKey)
            guard verified.deviceHash == DeviceID.deviceHash() else { return }
            try? Self.persist(blob: response.license)
            LicenseKeychain.saveToken(response.apiToken)
            payload = verified
            status = Self.status(for: verified)
            lastError = nil
        } catch {
            // no_subscription / transport — keep the current offline status.
        }
    }

 /// Refresh window before expiry: renew the offline
    /// blob a few days early so a lapsed network doesn't drop the user to grace.
    public nonisolated static let refreshWindow: TimeInterval = 3 * 86_400

    /// Refreshes the license blob when it is close to expiry (or already past
    /// it). No-op without an installed license + token, or when the blob is
    /// comfortably valid. Transport failure keeps the current offline status.
    public func refreshIfNeeded(now: Date = Date()) async {
        guard let payload, LicenseKeychain.readToken() != nil else { return }
        guard Self.shouldRefresh(exp: payload.exp, window: Self.refreshWindow, now: now) else { return }
        await refreshNow()
    }

    /// Forces a refresh against the backend and re-verifies the returned blob.
    /// Unlike `activate`/`startTrial`/`restorePurchase`, a definitive rejection
 /// here means the license already installed
    /// is no longer honored — revoked key/device, not just "couldn't reach the
    /// server" — so it clears the stale cached blob instead of leaving
    /// `status` showing whatever it was before this call.
    public func refreshNow() async {
        guard let token = LicenseKeychain.readToken() else { return }
        await run({ try await self.client.refresh(token: token) }, clearOnDefinitiveRejection: true)
    }

    nonisolated static func shouldRefresh(exp: Int64, window: TimeInterval, now: Date = Date()) -> Bool {
        Double(exp) - now.timeIntervalSince1970 <= window
    }

 /// Bearer token for the AI gateway, minted at
 /// activation and stored in the Keychain. Nil until activated.
    public nonisolated static func apiToken() -> String? {
        LicenseKeychain.readToken() ?? "dev-token"
    }

    /// Whether there's anything locally installed worth offering to sign out
    /// of — the blob file, a Keychain token, or both. Deliberately NOT
    /// `status.isEntitled`: the blob and the Keychain token are two
    /// separately-persisted things (`loadInstalled()`'s `try?` silently
    /// falls to `.none` on any verify failure, e.g. a stale build checking
    /// a real blob against the wrong key) and can fall out of sync — a
    /// non-entitled status is exactly the moment a user most needs Sign Out
    /// (an expired trial, or recovering from a stuck mismatch like that),
    /// so gating the button on entitlement hides it exactly when it's
    /// needed most.
    public var canSignOut: Bool {
        payload != nil || LicenseKeychain.readToken() != nil
    }

    /// Removes the installed license (sign out / deactivate locally).
    public func clear() {
        try? FileManager.default.removeItem(at: Self.blobURL())
        LicenseKeychain.deleteToken()
        payload = nil
        status = .none
    }

    private func run(
        _ activate: @escaping () async throws -> ActivationResponse,
        clearOnDefinitiveRejection: Bool = false
    ) async {
        lastError = nil
        do {
            let response = try await activate()
            let verified = try LicenseBlob.verify(response.license, publicKey: publicKey)
            guard verified.deviceHash == DeviceID.deviceHash() else {
                lastError = "License is bound to a different device"
                return
            }
            try? Self.persist(blob: response.license)
            LicenseKeychain.saveToken(response.apiToken)
            payload = verified
            status = Self.status(for: verified)
        } catch let error as APIError {
            lastError = error.code
            if clearOnDefinitiveRejection, Self.isDefinitiveRejection(error) {
                clear()
            }
        } catch let error as LicenseVerifyError {
            // A stable code, same convention as APIError.code above — the
            // default catch-all's `error.localizedDescription` produced
            // Swift's generic NSError bridging text ("The operation
            // couldn't be completed. (BerryLicense.LicenseVerifyError error
            // 2.)"), unreadable to a user reporting the bug and unmappable
            // by LicenseSupport.licenseErrorMessage's code switch, which
            // just passed it through raw.
            lastError = {
                switch error {
                case .malformed: "license_verify_malformed"
                case .badBase64: "license_verify_bad_base64"
                case .badSignature: "license_verify_bad_signature"
                case .badPayload: "license_verify_bad_payload"
                }
            }()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Whether a failed request means the backend has definitively rejected
    /// this token (revoked key/device) rather than the request merely failing
    /// to reach it. `plan_required` is the stable code `/v1/licenses/refresh`
    /// returns for an unknown/revoked token (`LicenseClient.refresh`); nothing
    /// else (a different `APIError` code, or a transport failure that never
    /// reaches this catch clause at all) should be treated as a rejection —
    /// staying silent on those is what lets the app work fully offline.
    nonisolated static func isDefinitiveRejection(_ error: APIError) -> Bool {
        error.code == "plan_required"
    }

    // MARK: - Load installed

    private func loadInstalled() {
        guard let token = try? String(contentsOf: Self.blobURL(), encoding: .utf8),
              let verified = try? LicenseBlob.verify(token, publicKey: publicKey),
              verified.deviceHash == DeviceID.deviceHash()
        else {
            status = .none
            return
        }
        payload = verified
        status = Self.status(for: verified)
    }

    // MARK: - Pure state computation (testable)

    nonisolated static func status(for payload: LicensePayload?, now: Date = Date()) -> LicenseStatus {
        guard let payload else { return .none }
        let secondsLeft = payload.exp - Int64(now.timeIntervalSince1970)
        let daysLeft = Int((Double(secondsLeft) / 86_400).rounded(.up))
        if payload.plan == "trial" {
            return secondsLeft > 0
                ? .trial(daysLeft: max(daysLeft, 0))
                : .trialExpired(version: payload.fallbackVer)
        }
        if secondsLeft > 0 {
            return .active(plan: payload.plan, daysLeft: max(daysLeft, 0))
        }
        let daysOver = Int((Double(-secondsLeft) / 86_400).rounded(.up))
        return daysOver <= graceDays
            ? .grace(plan: payload.plan, daysOver: daysOver)
            : .fallback(version: payload.fallbackVer)
    }

    nonisolated static func publicKey(fromBase64 base64: String) throws -> Curve25519.Signing.PublicKey {
        guard let data = Data(base64Encoded: base64) else { throw LicenseVerifyError.badBase64 }
        return try Curve25519.Signing.PublicKey(rawRepresentation: data)
    }

    // MARK: - Persistence

    static func blobURL() throws -> URL {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("BerryDB", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("license.blob")
    }

    static func persist(blob: String) throws {
        try blob.write(to: try blobURL(), atomically: true, encoding: .utf8)
    }
}
