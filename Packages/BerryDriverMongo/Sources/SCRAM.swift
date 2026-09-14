import CryptoKit
import Foundation

/// Pure SCRAM-SHA-256 client-side conversation (RFC 5802 algorithm, RFC 7677
/// hash choice) — MongoDB's default auth mechanism since 4.0. No networking:
/// `MongoWireClient` drives the two `saslStart`/`saslContinue` round trips and
/// feeds server responses in here. Verified byte-for-byte against RFC 7677
/// The spec's own worked example (`SCRAMTests`) — the same "verify against a real
/// vector, don't derive by hand" discipline `SigV4Signer` used for AWS SigV4
///
enum SCRAM {
    enum SCRAMError: Error, LocalizedError {
        case malformedServerMessage(String)
        case nonceMismatch
        case serverSignatureMismatch

        var errorDescription: String? {
            switch self {
            case .malformedServerMessage(let detail):
                return "Malformed SCRAM server message: \(detail)"
            case .nonceMismatch:
                return "SCRAM server nonce did not extend the client nonce"
            case .serverSignatureMismatch:
                return "SCRAM server signature verification failed"
            }
        }
    }

    static func generateNonce(byteCount: Int = 24) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
    }

    /// `message` is the actual SASL payload bytes sent on the wire (GS2
    /// header `n,,` — no channel binding, no authzid — + the bare message);
    /// `messageBare` is kept separately because the auth-message hash later
    /// needs the bare form without the GS2 header.
    struct ClientFirst {
        let message: String
        let messageBare: String
        let nonce: String
    }

    static func clientFirst(username: String, nonce: String) -> ClientFirst {
 // RFC 5802 "saslname" escaping — '=' and ',' would otherwise
        // collide with the message's own field/value delimiters.
        let escaped = username
            .replacingOccurrences(of: "=", with: "=3D")
            .replacingOccurrences(of: ",", with: "=2C")
        let bare = "n=\(escaped),r=\(nonce)"
        return ClientFirst(message: "n,,\(bare)", messageBare: bare, nonce: nonce)
    }

    struct ServerFirst {
        let nonce: String
        let salt: Data
        let iterations: Int
        /// The raw server-first-message text — folded into the auth message
 /// hash verbatim (RFC 5802), not reconstructed from the parsed
        /// fields.
        let raw: String
    }

    static func parseServerFirst(_ message: String) throws -> ServerFirst {
        let fields = parseFields(message)
        guard let nonce = fields["r"] else { throw SCRAMError.malformedServerMessage("missing r=") }
        guard let saltB64 = fields["s"], let salt = Data(base64Encoded: saltB64) else {
            throw SCRAMError.malformedServerMessage("missing/invalid s=")
        }
        guard let iterString = fields["i"], let iterations = Int(iterString) else {
            throw SCRAMError.malformedServerMessage("missing/invalid i=")
        }
        return ServerFirst(nonce: nonce, salt: salt, iterations: iterations, raw: message)
    }

    struct ClientFinal {
        let message: String
        let serverSignatureExpected: Data
    }

    /// Computes the client-final-message and the server signature this
 /// client independently expects back — RFC 5802's algorithm, SHA-256
    /// throughout (RFC 7677). For SCRAM-SHA-256 (unlike Mongo's legacy
    /// SCRAM-SHA-1/MONGODB-CR path) the password feeds PBKDF2 directly, no
    /// `MD5(user:mongo:pwd)` pre-digest.
    static func clientFinal(password: String, clientFirst: ClientFirst, serverFirst: ServerFirst) throws -> ClientFinal {
        guard serverFirst.nonce.hasPrefix(clientFirst.nonce) else { throw SCRAMError.nonceMismatch }

        let saltedPassword = pbkdf2HMACSHA256(
            password: Array(password.utf8), salt: [UInt8](serverFirst.salt), iterations: serverFirst.iterations
        )
        let clientKey = hmac(key: saltedPassword, data: Array("Client Key".utf8))
        let storedKey = sha256(clientKey)

        let channelBindingB64 = "biws" // base64("n,,") — no channel binding
        let finalWithoutProof = "c=\(channelBindingB64),r=\(serverFirst.nonce)"
        let authMessage = "\(clientFirst.messageBare),\(serverFirst.raw),\(finalWithoutProof)"

        let clientSignature = hmac(key: storedKey, data: Array(authMessage.utf8))
        let clientProof = zip(clientKey, clientSignature).map { $0 ^ $1 }

        let serverKey = hmac(key: saltedPassword, data: Array("Server Key".utf8))
        let serverSignature = hmac(key: serverKey, data: Array(authMessage.utf8))

        let message = "\(finalWithoutProof),p=\(Data(clientProof).base64EncodedString())"
        return ClientFinal(message: message, serverSignatureExpected: Data(serverSignature))
    }

    static func verifyServerFinal(_ message: String, expected: Data) throws {
        let fields = parseFields(message)
        guard let vB64 = fields["v"], let v = Data(base64Encoded: vB64) else {
            throw SCRAMError.malformedServerMessage("missing/invalid v=")
        }
        guard v == expected else { throw SCRAMError.serverSignatureMismatch }
    }

    // MARK: - Parsing

    private static func parseFields(_ message: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in message.split(separator: ",") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            result[String(part[part.startIndex..<eq])] = String(part[part.index(after: eq)...])
        }
        return result
    }

    // MARK: - Crypto primitives (CryptoKit — Apple platform framework, no vendored dependency)

    private static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: Data(bytes)))
    }

    private static func hmac(key: [UInt8], data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: Data(data), using: SymmetricKey(data: Data(key))))
    }

    /// PBKDF2-HMAC-SHA256 (RFC 2898) — CryptoKit has no PBKDF2 primitive, so
    /// this is built from `HMAC<SHA256>` directly (same zero-dependency
    /// reasoning `SigV4Signer` used for its own HMAC chain,
 /// Verified against RFC 7677's test vector,
    /// not hand-derived.
    private static func pbkdf2HMACSHA256(password: [UInt8], salt: [UInt8], iterations: Int, keyLength: Int = 32) -> [UInt8] {
        var result: [UInt8] = []
        var blockIndex: UInt32 = 1
        while result.count < keyLength {
            var saltBlock = salt
            saltBlock.append(contentsOf: withUnsafeBytes(of: blockIndex.bigEndian) { Array($0) })
            var u = hmac(key: password, data: saltBlock)
            var t = u
            if iterations > 1 {
                for _ in 1..<iterations {
                    u = hmac(key: password, data: u)
                    for i in 0..<t.count { t[i] ^= u[i] }
                }
            }
            result.append(contentsOf: t)
            blockIndex += 1
        }
        return Array(result.prefix(keyLength))
    }
}
