import CryptoKit
import Foundation

/// Hand-rolled AWS Signature Version 4 request signer for DynamoDB auth
/// (docs/architecture/12 §4). `aws-sdk-swift` (the doc's stated preference)
/// was tried first and abandoned — see docs/architecture/12 §4 "Trạng thái
/// hiện thực" for why. Zero external dependency: CryptoKit is an Apple
/// platform framework already used elsewhere in the app (BerryLicense,
/// BerryTunnel), not a new SwiftPM package.
///
/// Implements exactly the algorithm documented at
/// https://docs.aws.amazon.com/general/latest/gr/sigv4-signed-request-examples.html
/// — canonical request → string to sign → derived signing key → signature.
/// Verified byte-correct against AWS's own published test vectors
/// (`SigV4SignerTests`, `AKIDEXAMPLE`/service `"service"` fixtures).
enum SigV4Signer {
    struct Credentials: Sendable {
        let accessKeyID: String
        let secretAccessKey: String
        let sessionToken: String?

        init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
            self.accessKeyID = accessKeyID
            self.secretAccessKey = secretAccessKey
            self.sessionToken = sessionToken
        }
    }

    /// Adds `X-Amz-Date` (+ `X-Amz-Security-Token` when a session token is
    /// present) and a signed `Authorization` header to `request`. Every other
    /// header already set on `request` (e.g. `Content-Type`, `X-Amz-Target`)
    /// is included in the signature — callers must set those BEFORE calling
    /// `sign`, since headers added afterward are not covered by it.
    static func sign(
        _ request: inout URLRequest,
        body: Data,
        credentials: Credentials,
        region: String,
        service: String,
        date: Date = Date()
    ) {
        guard let url = request.url, let host = url.host else { return }
        let method = request.httpMethod ?? "POST"

        let amzDate = amzDateFormatter.string(from: date)
        let dateStamp = String(amzDate.prefix(8))

        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if let token = credentials.sessionToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        // Non-default port (dynamodb-local runs on a custom port) — URLSession
        // sends "Host: host:port" on the wire in that case, so the signed
        // value must match or the server-side signature check fails.
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host

        var headers: [String: String] = ["host": hostHeader]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            headers[name.lowercased()] = value.trimmingCharacters(in: .whitespaces)
        }
        let signedHeaderNames = headers.keys.sorted()
        let canonicalHeaders = signedHeaderNames.map { "\($0):\(headers[$0]!)\n" }.joined()
        let signedHeaders = signedHeaderNames.joined(separator: ";")

        let canonicalRequest = [
            method,
            canonicalURI(url),
            canonicalQuery(url),
            canonicalHeaders,
            signedHeaders,
            sha256Hex(body),
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signingKey = deriveSigningKey(
            secret: credentials.secretAccessKey, dateStamp: dateStamp, region: region, service: service
        )
        let signature = hmacHex(key: signingKey, data: Data(stringToSign.utf8))

        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(credentialScope), "
                + "SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    // MARK: - Canonical request pieces

    static func canonicalURI(_ url: URL) -> String {
        let path = url.path.isEmpty ? "/" : url.path
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { awsURIEncode(String($0), encodeSlash: true) }
            .joined(separator: "/")
    }

    static func canonicalQuery(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty else { return "" }
        let encoded = items.map {
            (awsURIEncode($0.name, encodeSlash: true), awsURIEncode($0.value ?? "", encodeSlash: true))
        }
        return encoded.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    /// RFC 3986 unreserved characters pass through verbatim; everything else
    /// (including space, which becomes `%20` — never `+`) is percent-encoded
    /// as uppercase hex, one `%XX` per UTF-8 byte.
    static func awsURIEncode(_ s: String, encodeSlash: Bool) -> String {
        var result = ""
        for scalar in s.unicodeScalars {
            if isUnreserved(scalar) {
                result.unicodeScalars.append(scalar)
            } else if scalar == "/" && !encodeSlash {
                result.append("/")
            } else {
                for byte in String(scalar).utf8 {
                    result += String(format: "%%%02X", byte)
                }
            }
        }
        return result
    }

    private static func isUnreserved(_ s: Unicode.Scalar) -> Bool {
        (s >= "A" && s <= "Z") || (s >= "a" && s <= "z") || (s >= "0" && s <= "9")
            || s == "-" || s == "_" || s == "." || s == "~"
    }

    // MARK: - Crypto primitives (CryptoKit — no vendored dependency)

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static func hmacHex(key: Data, data: Data) -> String {
        hmac(key: key, data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// DateKey → DateRegionKey → DateRegionServiceKey → SigningKey, each a
    /// keyed HMAC over the previous result (docs/architecture/12 §4).
    static func deriveSigningKey(secret: String, dateStamp: String, region: String, service: String) -> Data {
        let dateKey = hmac(key: Data(("AWS4" + secret).utf8), data: Data(dateStamp.utf8))
        let regionKey = hmac(key: dateKey, data: Data(region.utf8))
        let serviceKey = hmac(key: regionKey, data: Data(service.utf8))
        return hmac(key: serviceKey, data: Data("aws4_request".utf8))
    }

    private static let amzDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}
