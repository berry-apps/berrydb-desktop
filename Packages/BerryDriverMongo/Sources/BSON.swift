import BerryDataSourceKit
import Foundation

/// Pure BSON binary <-> `BerryDocument` codec — no networking
/// Hand-rolled per the BSON
/// spec (bsonspec.org); encode/decode verified against MongoDB's own
/// `bson-corpus` conformance vectors (`BSONTests`) rather than derived by
/// hand, same "verify against a real vector" discipline as `SigV4Signer`
///
///
/// Deliberately narrower than the full BSON type system: types with no
/// `BerryDocument` case or no realistic use in a document a BerryDB user
/// would build (Decimal128, Timestamp, DBPointer, Code-with-scope,
/// MinKey/MaxKey, Regex) decode best-effort into the closest `BerryDocument`
/// case (documented per-case below) but are never *encoded* — a caller has
/// no way to construct e.g. a Decimal128 through `BerryDocument`.
enum BSON {
    private enum TypeByte {
        static let double: UInt8 = 0x01
        static let string: UInt8 = 0x02
        static let document: UInt8 = 0x03
        static let array: UInt8 = 0x04
        static let binary: UInt8 = 0x05
        static let undefinedDeprecated: UInt8 = 0x06
        static let objectID: UInt8 = 0x07
        static let bool: UInt8 = 0x08
        static let datetime: UInt8 = 0x09
        static let null: UInt8 = 0x0A
        static let regex: UInt8 = 0x0B
        static let dbPointerDeprecated: UInt8 = 0x0C
        static let jsCode: UInt8 = 0x0D
        static let symbolDeprecated: UInt8 = 0x0E
        static let jsCodeWithScope: UInt8 = 0x0F
        static let int32: UInt8 = 0x10
        static let timestamp: UInt8 = 0x11
        static let int64: UInt8 = 0x12
        static let decimal128: UInt8 = 0x13
        static let minKey: UInt8 = 0xFF
        static let maxKey: UInt8 = 0x7F
    }

    enum BSONError: Error, LocalizedError {
        case truncated(String)

        var errorDescription: String? {
            switch self {
            case .truncated(let where_):
                return "Truncated or malformed BSON while reading \(where_)"
            }
        }
    }

    // MARK: - Encode

    /// `doc` MUST be `.object` — BSON documents are always field lists; a
    /// non-object top level encodes as an empty document (defensive, should
    /// never happen given how callers build command bodies).
    static func encode(_ doc: BerryDocument) -> Data {
        guard case .object(let fields) = doc else { return encodeDocument([]) }
        return encodeDocument(fields)
    }

    static func encodeDocument(_ fields: [(String, BerryDocument)]) -> Data {
        var body = Data()
        for (name, value) in fields {
            encodeElement(name: name, value: value, into: &body)
        }
        body.append(0)
        var out = Data(capacity: body.count + 4)
        out.append(int32LE(Int32(body.count + 4)))
        out.append(body)
        return out
    }

    private static func encodeElement(name: String, value: BerryDocument, into data: inout Data) {
        switch value {
        case .null:
            data.append(TypeByte.null)
            appendCString(name, &data)
        case .bool(let b):
            data.append(TypeByte.bool)
            appendCString(name, &data)
            data.append(b ? 1 : 0)
        case .int(let i):
            if let i32 = Int32(exactly: i) {
                data.append(TypeByte.int32)
                appendCString(name, &data)
                data.append(int32LE(i32))
            } else {
                data.append(TypeByte.int64)
                appendCString(name, &data)
                data.append(int64LE(i))
            }
        case .double(let d):
            data.append(TypeByte.double)
            appendCString(name, &data)
            data.append(uint64LE(d.bitPattern))
        case .string(let s):
            data.append(TypeByte.string)
            appendCString(name, &data)
            appendBSONString(s, &data)
        case .binary(let bytes):
            data.append(TypeByte.binary)
            appendCString(name, &data)
            data.append(int32LE(Int32(bytes.count)))
            data.append(0x00) // subtype: generic
            data.append(bytes)
        case .objectID(let hex):
            data.append(TypeByte.objectID)
            appendCString(name, &data)
            data.append(objectIDBytes(hex))
        case .date(let date):
            data.append(TypeByte.datetime)
            appendCString(name, &data)
            let millis = Int64((date.timeIntervalSince1970 * 1000).rounded())
            data.append(int64LE(millis))
        case .vector(let floats):
            // No general-document BSON vector type — widen to an array of
            // doubles (lossy Float -> Double). Decode never re-produces
 // `.vector` for a plain numeric array:
            // this is a one-way write path, not a round-trip.
            data.append(TypeByte.array)
            appendCString(name, &data)
            let items = floats.enumerated().map { (String($0.offset), BerryDocument.double(Double($0.element))) }
            data.append(encodeDocument(items))
        case .array(let items):
            data.append(TypeByte.array)
            appendCString(name, &data)
            let fields = items.enumerated().map { (String($0.offset), $0.element) }
            data.append(encodeDocument(fields))
        case .object(let fields):
            data.append(TypeByte.document)
            appendCString(name, &data)
            data.append(encodeDocument(fields))
        }
    }

    private static func appendCString(_ s: String, _ data: inout Data) {
        data.append(contentsOf: Array(s.utf8))
        data.append(0)
    }

    private static func appendBSONString(_ s: String, _ data: inout Data) {
        let bytes = Array(s.utf8)
        data.append(int32LE(Int32(bytes.count + 1)))
        data.append(contentsOf: bytes)
        data.append(0)
    }

    /// Malformed/short hex (not a real 24-char ObjectId hex string) zero-pads
    /// rather than throwing — best-effort, matches `BerryDocument`'s
    /// no-information-losing-but-no-hard-crash-either philosophy for edge
    /// inputs the UI wouldn't normally construct.
    private static func objectIDBytes(_ hex: String) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(12)
        let chars = Array(hex)
        var i = 0
        while i + 2 <= chars.count, bytes.count < 12 {
            if let b = UInt8(String(chars[i..<i + 2]), radix: 16) { bytes.append(b) }
            i += 2
        }
        while bytes.count < 12 { bytes.append(0) }
        return Data(bytes)
    }

    static func int32LE(_ v: Int32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    static func uint32LE(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    static func int64LE(_ v: Int64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    static func uint64LE(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    // MARK: - Decode

    static func decode(_ data: Data) throws -> BerryDocument {
        let bytes = [UInt8](data)
        var offset = 0
        return try decodeDocument(bytes, at: &offset)
    }

    /// Decodes one BSON document starting at `offset`, advancing `offset`
    /// past it — used both by `decode(_:)` and by `MongoOpMsg` to pull a
    /// document out of a larger OP_MSG section without knowing its length in
    /// advance (BSON documents are self-length-prefixed).
    static func decodeDocument(_ bytes: [UInt8], at offset: inout Int) throws -> BerryDocument {
        .object(try decodeDocumentFields(bytes, &offset))
    }

    private static func decodeDocumentFields(_ bytes: [UInt8], _ offset: inout Int) throws -> [(String, BerryDocument)] {
        let start = offset
        let length = try readInt32(bytes, &offset)
        guard length >= 5, start + Int(length) <= bytes.count else {
            throw BSONError.truncated("document length")
        }
        let end = start + Int(length)
        var fields: [(String, BerryDocument)] = []
        while offset < end - 1 {
            let type = bytes[offset]
            offset += 1
            let name = try readCString(bytes, &offset)
            let value = try decodeValue(type: type, bytes, &offset)
            fields.append((name, value))
        }
        offset = end // trust the length field; skips the trailing 0x00 terminator
        return fields
    }

    private static func decodeValue(type: UInt8, _ bytes: [UInt8], _ offset: inout Int) throws -> BerryDocument {
        switch type {
        case TypeByte.double:
            return .double(Double(bitPattern: try readUInt64(bytes, &offset)))
        case TypeByte.string:
            return .string(try readBSONString(bytes, &offset))
        case TypeByte.document:
            return try decodeDocument(bytes, at: &offset)
        case TypeByte.array:
            let fields = try decodeDocumentFields(bytes, &offset)
            return .array(fields.map(\.1))
        case TypeByte.binary:
            let len = try readInt32(bytes, &offset)
            guard len >= 0, offset + Int(len) + 1 <= bytes.count else { throw BSONError.truncated("binary") }
            let subtype = bytes[offset]
            offset += 1
            let payload = Data(bytes[offset..<offset + Int(len)])
            offset += Int(len)
            if subtype == 0x09, let vector = decodeVectorSubtype(payload) {
                return .vector(vector)
            }
            return .binary(payload)
        case TypeByte.undefinedDeprecated:
            return .null
        case TypeByte.objectID:
            guard offset + 12 <= bytes.count else { throw BSONError.truncated("objectId") }
            let hex = bytes[offset..<offset + 12].map { String(format: "%02x", $0) }.joined()
            offset += 12
            return .objectID(hex)
        case TypeByte.bool:
            guard offset < bytes.count else { throw BSONError.truncated("bool") }
            let b = bytes[offset]
            offset += 1
            return .bool(b != 0)
        case TypeByte.datetime:
            let millis = try readInt64(bytes, &offset)
            return .date(Date(timeIntervalSince1970: Double(millis) / 1000))
        case TypeByte.null:
            return .null
        case TypeByte.regex:
            let pattern = try readCString(bytes, &offset)
            let options = try readCString(bytes, &offset)
            return .string("/\(pattern)/\(options)")
        case TypeByte.dbPointerDeprecated:
            _ = try readBSONString(bytes, &offset)
            guard offset + 12 <= bytes.count else { throw BSONError.truncated("dbPointer") }
            offset += 12
            return .null
        case TypeByte.jsCode, TypeByte.symbolDeprecated:
            return .string(try readBSONString(bytes, &offset))
        case TypeByte.jsCodeWithScope:
            let start = offset
            let total = try readInt32(bytes, &offset)
            let code = try readBSONString(bytes, &offset)
            offset = start + Int(total) // skip the scope document — best-effort, code only
            return .string(code)
        case TypeByte.int32:
            return .int(Int64(try readInt32(bytes, &offset)))
        case TypeByte.timestamp:
            // Internal replication type (uint32 increment + uint32 seconds);
            // no `BerryDocument` case fits it — decode as the raw 8-byte
            // value, best-effort, never constructed by this driver.
            return .int(try readInt64(bytes, &offset))
        case TypeByte.int64:
            return .int(try readInt64(bytes, &offset))
        case TypeByte.decimal128:
            guard offset + 16 <= bytes.count else { throw BSONError.truncated("decimal128") }
            let payload = Data(bytes[offset..<offset + 16])
            offset += 16
            return .binary(payload) // opaque — no BigDecimal type to decode into
        case TypeByte.minKey, TypeByte.maxKey:
            return .null
        default:
            throw BSONError.truncated("unsupported BSON type 0x\(String(format: "%02x", type))")
        }
    }

    /// Atlas Vector Search binary subtype (0x09): 1 dtype byte + 1 padding
    /// byte + packed vector data. Only float32 (dtype 0x27) decodes to
    /// `.vector`; other dtypes (int8/packed-bit quantized vectors) fall back
    /// to `.binary` via the caller — narrow, best-effort support, not a goal
 /// of this driver (Mongo vector search is out of scope).
    private static func decodeVectorSubtype(_ payload: Data) -> [Float]? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 2, bytes[0] == 0x27 else { return nil }
        let floatBytes = Array(bytes[2...])
        guard !floatBytes.isEmpty, floatBytes.count % 4 == 0 else { return nil }
        var result: [Float] = []
        var i = 0
        while i < floatBytes.count {
            let bits = UInt32(floatBytes[i]) | UInt32(floatBytes[i + 1]) << 8
                | UInt32(floatBytes[i + 2]) << 16 | UInt32(floatBytes[i + 3]) << 24
            result.append(Float(bitPattern: bits))
            i += 4
        }
        return result
    }

    static func readCString(_ bytes: [UInt8], _ offset: inout Int) throws -> String {
        var end = offset
        while end < bytes.count, bytes[end] != 0 { end += 1 }
        guard end < bytes.count else { throw BSONError.truncated("cstring") }
        let s = String(decoding: bytes[offset..<end], as: UTF8.self)
        offset = end + 1
        return s
    }

    private static func readBSONString(_ bytes: [UInt8], _ offset: inout Int) throws -> String {
        let length = try readInt32(bytes, &offset)
        guard length >= 1, offset + Int(length) <= bytes.count else { throw BSONError.truncated("string") }
        let s = String(decoding: bytes[offset..<offset + Int(length) - 1], as: UTF8.self)
        offset += Int(length)
        return s
    }

    static func readInt32(_ bytes: [UInt8], _ offset: inout Int) throws -> Int32 {
        Int32(bitPattern: try readUInt32(bytes, &offset))
    }

    static func readUInt32(_ bytes: [UInt8], _ offset: inout Int) throws -> UInt32 {
        guard offset + 4 <= bytes.count else { throw BSONError.truncated("int32") }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[offset + i]) << (8 * i) }
        offset += 4
        return v
    }

    static func readInt64(_ bytes: [UInt8], _ offset: inout Int) throws -> Int64 {
        Int64(bitPattern: try readUInt64(bytes, &offset))
    }

    static func readUInt64(_ bytes: [UInt8], _ offset: inout Int) throws -> UInt64 {
        guard offset + 8 <= bytes.count else { throw BSONError.truncated("int64") }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[offset + i]) << (8 * i) }
        offset += 8
        return v
    }
}
