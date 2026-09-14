import Foundation

/// Successful activation/trial response.
public struct ActivationResponse: Decodable, Sendable {
    public let license: String
    public let apiToken: String
    public let plan: String
    public let exp: Int64

    enum CodingKeys: String, CodingKey {
        case license, plan, exp
        case apiToken = "api_token"
    }
}

/// Response to a topup request.
public struct TopupResponse: Decodable, Sendable {
    public let checkoutURL: String

    enum CodingKeys: String, CodingKey {
        case checkoutURL = "checkout_url"
    }
}

/// Stable API error — the client shows behavior by `code`, never parses the
/// message (point 4).
public struct APIError: Error, Equatable, Sendable, Decodable {
    public let code: String
    public let message: String
}

public enum LicenseClientError: Error, Equatable {
    case transport
    case badResponse
}

/// Without this, `error.localizedDescription` falls back to Foundation's
/// generic NSError bridging ("The operation couldn't be completed.
/// BerryLicense.LicenseClientError error 0.") — meaningless to a user, and
/// worse, it silently defeats `licenseErrorMessage`'s `"transport"`/
/// `"badResponse"` mapping (BerryUI/LicenseSupport.swift), which matches on
/// this exact string. `errorDescription` returns the bare code, not a
/// human sentence, on purpose — `LicenseManager` treats every error's
/// `localizedDescription` uniformly as a code to look up (mirroring
/// `APIError.code`), and `licenseErrorMessage` is the one place that maps a
/// code to user-facing text (client renders by
/// code).
extension LicenseClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .transport: "transport"
        case .badResponse: "badResponse"
        }
    }
}

/// Thin client for berrydb-backend's licensing + pricing endpoints. Networking
/// is isolated here so the rest of the app depends only on the results.
public struct LicenseClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func activate(key: String, deviceHash: String, appVersion: String) async throws -> ActivationResponse {
        try await post("/v1/licenses/activate", body: [
            "key": key, "device_hash": deviceHash, "app_version": appVersion,
        ])
    }

    /// `email` is required server-side (`email_required`) — trial usage/cost
    /// needs to be attributable, and it's the only way admin can disable/cap
    /// a specific trial account.
    public func trial(deviceHash: String, email: String, appVersion: String) async throws -> ActivationResponse {
        try await post("/v1/licenses/trial", body: [
            "device_hash": deviceHash, "email": email, "app_version": appVersion,
        ])
    }

    /// After a Paddle checkout, fetch the license the webhook granted this
 /// device. Throws `no_subscription` (404) until
    /// the payment webhook has landed.
    public func licenseByDevice(deviceHash: String) async throws -> ActivationResponse {
        try await post("/v1/licenses/by-device", body: ["device_hash": deviceHash])
    }

 /// Restore a purchase by the email used at checkout
    /// — the fallback when the checkout didn't carry a device hash.
    public func licenseByEmail(email: String, deviceHash: String) async throws -> ActivationResponse {
        try await post("/v1/licenses/by-email", body: ["email": email, "device_hash": deviceHash])
    }

 /// Re-issues a fresh signed blob for a live token.
    /// Bearer-authenticated; an unknown token throws `APIError(plan_required)`.
    public func refresh(token: String) async throws -> ActivationResponse {
        try await post("/v1/licenses/refresh", body: [:], bearer: token)
    }

 /// Starts an AI-credit deposit: opens a
    /// Paddle checkout for a custom amount. The returned URL already carries
    /// this device's binding as Paddle `custom_data` (set server-side at
    /// transaction creation) — unlike the old Subscribe flow, the caller
    /// doesn't need to append anything to it. Bearer-authenticated; the
    /// backend rejects an amount below its admin-configured minimum with
    /// `APIError(code: "amount_too_small")`.
    public func topup(amountCents: Int, token: String) async throws -> TopupResponse {
        try await post("/v1/ai/topup", body: ["amount_cents": amountCents], bearer: token)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any], bearer: String? = nil) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LicenseClientError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw LicenseClientError.badResponse }
        if (200..<300).contains(http.statusCode) {
            return try JSONDecoder().decode(T.self, from: data)
        }
        // Non-2xx carries a stable { code, message } body.
        if let apiError = try? JSONDecoder().decode(APIError.self, from: data) {
            throw apiError
        }
        throw LicenseClientError.badResponse
    }
}
