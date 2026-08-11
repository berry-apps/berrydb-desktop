import Crypto
import Foundation

/// Parses UNENCRYPTED OpenSSH ECDSA private keys (P-256/384/521) — the piece
/// Citadel's own key loader doesn't cover (KN-03, docs/architecture/07 §4).
/// Format: openssh-key-v1 (magic, cipher, kdf, one pubkey blob, one privkey
/// blob with check ints, key type, curve, point Q, scalar d, comment, padding).
enum OpenSSHECDSAKey {
    enum Key {
        case p256(P256.Signing.PrivateKey)
        case p384(P384.Signing.PrivateKey)
        case p521(P521.Signing.PrivateKey)
    }

    enum ParseError: Error, Equatable {
        case notOpenSSH
        case encrypted
        case notECDSA
        case malformed(String)
    }

    static func parse(pem: String) throws -> Key {
        var body = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"),
              body.hasSuffix("-----END OPENSSH PRIVATE KEY-----")
        else { throw ParseError.notOpenSSH }
        body.removeFirst("-----BEGIN OPENSSH PRIVATE KEY-----".count)
        body.removeLast("-----END OPENSSH PRIVATE KEY-----".count)
        let base64 = body.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        guard let data = Data(base64Encoded: base64) else {
            throw ParseError.malformed("invalid base64")
        }

        var reader = Reader(data: data)
        guard reader.readMagic("openssh-key-v1\0") else { throw ParseError.notOpenSSH }
        guard let cipher = reader.readString(), let kdf = reader.readString(),
              reader.readBlob() != nil,                      // kdf options
              let keyCount = reader.readUInt32(), keyCount == 1,
              reader.readBlob() != nil,                      // public key blob
              var priv = (reader.readBlob().map { Reader(data: $0) })
        else { throw ParseError.malformed("truncated header") }
        guard cipher == "none", kdf == "none" else { throw ParseError.encrypted }

        guard let check1 = priv.readUInt32(), let check2 = priv.readUInt32(),
              check1 == check2,
              let keyType = priv.readString()
        else { throw ParseError.malformed("bad private block") }
        guard keyType.hasPrefix("ecdsa-sha2-nistp") else { throw ParseError.notECDSA }
        guard priv.readString() != nil,                      // curve name
              priv.readBlob() != nil,                        // public point Q
              let scalar = priv.readBlob()                   // private scalar d (mpint)
        else { throw ParseError.malformed("missing scalar") }

        // The scalar is an mpint: strip a leading zero, then left-pad to the
        // curve's field size for CryptoKit's rawRepresentation.
        var raw = [UInt8](scalar)
        if raw.first == 0 { raw.removeFirst() }
        func padded(_ size: Int) -> Data {
            Data(repeating: 0, count: max(0, size - raw.count)) + Data(raw)
        }
        do {
            switch keyType {
            case "ecdsa-sha2-nistp256":
                return .p256(try P256.Signing.PrivateKey(rawRepresentation: padded(32)))
            case "ecdsa-sha2-nistp384":
                return .p384(try P384.Signing.PrivateKey(rawRepresentation: padded(48)))
            case "ecdsa-sha2-nistp521":
                return .p521(try P521.Signing.PrivateKey(rawRepresentation: padded(66)))
            default:
                throw ParseError.notECDSA
            }
        } catch let error as ParseError {
            throw error
        } catch {
            throw ParseError.malformed("scalar rejected: \(error)")
        }
    }

    /// Minimal SSH wire-format reader (uint32-length-prefixed blobs).
    private struct Reader {
        let data: Data
        var offset = 0

        init(data: Data) { self.data = data }

        mutating func readMagic(_ magic: String) -> Bool {
            let bytes = Array(magic.utf8)
            guard data.count >= offset + bytes.count else { return false }
            let slice = [UInt8](data[data.startIndex + offset..<data.startIndex + offset + bytes.count])
            guard slice == bytes else { return false }
            offset += bytes.count
            return true
        }

        mutating func readUInt32() -> UInt32? {
            guard data.count >= offset + 4 else { return nil }
            let start = data.startIndex + offset
            let value = data[start..<start + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            offset += 4
            return value
        }

        mutating func readBlob() -> Data? {
            guard let length = readUInt32(),
                  data.count >= offset + Int(length) else { return nil }
            let start = data.startIndex + offset
            let blob = data[start..<start + Int(length)]
            offset += Int(length)
            return Data(blob)
        }

        mutating func readString() -> String? {
            readBlob().flatMap { String(data: $0, encoding: .utf8) }
        }
    }
}
